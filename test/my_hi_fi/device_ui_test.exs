defmodule MyHiFi.DeviceUiTest do
  # It reads the player, which one process holds for the whole firmware.
  use MyHiFi.DataCase, async: false

  import ExUnit.CaptureLog

  alias MyHiFi.DeviceUi
  alias MyHiFi.Event
  alias MyHiFi.Event.Hint
  alias MyHiFi.Event.Input
  alias MyHiFi.Event.Player
  alias MyHiFi.Event.View
  alias MyHiFi.Output.Volume
  alias MyHiFi.Peripheral.PirateAudio
  alias MyHiFi.Peripheral.PiTft
  alias MyHiFi.Playback
  alias MyHiFi.Test.Stations
  alias MyHiFi.Test.TwoCardOutput

  setup do
    # `MyHiFi.Application` starts none of these in the test environment, so each test
    # holds one of its own and no test inherits a listener that it did not ask for. The
    # name is the one that the firmware uses, because these tests read it back.
    start_supervised!(MyHiFi.DeviceUi)

    :ok = Event.subscribe(:player)
    on_exit(fn -> Playback.standby(false) end)

    :ok
  end

  # Take every message that is waiting, so a test reads what it caused and nothing that
  # its own setup caused.
  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end

  defp station(title), do: Stations.create(%{country_code: "NZ", title: title})

  defp press(button, peripheral \\ PiTft, hold \\ :short) do
    Event.publish(:input, %Input.ButtonPressed{
      peripheral: peripheral,
      button: button,
      hold: hold
    })
  end

  describe "the buttons of the PiTFT" do
    test "the first button enters standby, and the next press leaves it" do
      press(1)
      assert_receive %Player.Standby{entered?: true}, 5000

      press(1)
      assert_receive %Player.Standby{entered?: false}, 5000
    end

    # The queue is empty in this test, so the player answers that there is no such
    # track. A control of a person must never stop the process that reads it.
    #
    # The reason goes in the log at the level of information, and `config/test.exs`
    # holds the level at warning, so this test raises it while it reads the log.
    test "a track control that can do nothing writes the reason and stays alive" do
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      log =
        capture_log(fn ->
          press(2)
          press(4)
          press(3)
          Process.sleep(200)
        end)

      assert log =~ "The control did nothing"
      assert Process.alive?(Process.whereis(MyHiFi.DeviceUi))
    end

    test "a button that this device does not know does nothing" do
      press(9)
      Process.sleep(100)

      assert Process.alive?(Process.whereis(MyHiFi.DeviceUi))
      refute_receive %Player.Standby{}, 200
    end
  end

  # **The menu is the click wheel of the device.** `MyHiFi.DeviceUi` owns where a person
  # is, and `MyHiFi.DeviceUi.Menu` owns the tree. A screen reads the events.
  describe "the menu" do
    # A press on a track plays it, and the player is one process for the whole
    # firmware, so this leaves it as it found it.
    setup do
      MyHiFi.Player.stop()
      Playback.clear_queue!()
      :ok = Event.subscribe(:view)
      :ok = Event.subscribe(:hint)

      on_exit(fn ->
        MyHiFi.Player.stop()
        Playback.clear_queue!()
      end)

      %{}
    end

    test "a hold of the play button opens it at the root" do
      press(3, PiTft, :long)

      assert_receive %View.MenuShown{title: "Menu", index: 0, depth: 0} = shown, 5000
      assert %{title: "Now playing"} = hd(shown.rows)
      assert_receive %Hint.Detents{count: count, index: 0}, 5000
      assert count == length(shown.rows)

      assert DeviceUi.places() == [:root]
    end

    test "the buttons move through the level, and the ends are stops" do
      press(3, PiTft, :long)
      assert_receive %View.MenuShown{index: 0}, 5000

      press(4)
      assert_receive %View.MenuShown{index: 1}, 5000

      press(2)
      assert_receive %View.MenuShown{index: 0}, 5000

      # The list does not go round: a knob with detents reads the count of the level.
      press(2)
      assert_receive %View.MenuShown{index: 0}, 5000
    end

    test "a press opens the row, and a back leaves it" do
      press(3, PiTft, :long)
      assert_receive %View.MenuShown{}, 5000

      press(4)
      assert_receive %View.MenuShown{index: 1}, 5000

      press(3)
      assert_receive %View.MenuShown{depth: 1}, 5000
      assert [_root, _source] = DeviceUi.places()

      press(1)
      assert_receive %View.MenuShown{depth: 0, index: 1}, 5000
      assert DeviceUi.places() == [:root]
    end

    test "a back at the root closes the menu" do
      press(3, PiTft, :long)
      assert_receive %View.MenuShown{}, 5000

      press(1)
      assert_receive %View.MenuClosed{}, 5000
      assert_receive %Hint.Detents{count: 0}, 5000
      assert DeviceUi.places() == []
    end

    # The way out is the first row, so a person who opened the menu by mistake presses
    # the button that they are already on.
    test "the first row closes the menu" do
      press(3, PiTft, :long)
      assert_receive %View.MenuShown{index: 0}, 5000

      press(3)
      assert_receive %View.MenuClosed{}, 5000
      assert DeviceUi.places() == []
    end

    test "the standby row acts on the device, and the menu goes" do
      press(3, PiTft, :long)
      assert_receive %View.MenuShown{rows: rows}, 5000

      Enum.each(1..(length(rows) - 1), fn _step -> press(4) end)
      press(3)

      assert_receive %Player.Standby{entered?: true}, 5000
      assert_receive %View.MenuClosed{}, 5000
    end

    # **A press that plays leaves the menu**, because a person who chose a track wants
    # to read what plays.
    test "a track plays, and the menu goes" do
      station("Alpha")

      press(3, PiTft, :long)
      assert_receive %View.MenuShown{rows: rows}, 5000

      radio = Enum.find_index(rows, &(&1.title == "Internet radio"))
      Enum.each(1..radio, fn _step -> press(4) end)
      press(3)
      assert_receive %View.MenuShown{title: "Internet radio"}, 5000

      # Favourites is the first branch of internet radio, and Countries is the second.
      press(4)
      press(3)
      assert_receive %View.MenuShown{title: "Countries"}, 5000

      press(3)
      assert_receive %View.MenuShown{title: "NZ", rows: [%{title: "Alpha"}]}, 5000

      press(3)
      assert_receive %View.MenuClosed{}, 5000
      assert DeviceUi.places() == []
      assert Playback.queue!() |> length() == 1
    end

    # The transport takes the row of four while the menu is closed, and the menu takes
    # it while the menu is open.
    test "the transport is quiet while the menu is open" do
      press(3, PiTft, :long)
      assert_receive %View.MenuShown{}, 5000
      flush()

      press(1)
      assert_receive %View.MenuClosed{}, 5000
      refute_receive %Player.Standby{}, 200
    end

    # A board of two buttons carries three controls of the transport already, and a tree
    # needs four.
    test "a board of two buttons reads no menu" do
      press(1, PirateAudio, :long)

      assert_receive %Player.Standby{entered?: true}, 5000
      refute_receive %View.MenuShown{}, 200
      assert DeviceUi.places() == []
    end
  end

  test "an event of the input topic that it cannot read does nothing" do
    Event.publish(:input, %URI{})
    Process.sleep(100)

    assert Process.alive?(Process.whereis(MyHiFi.DeviceUi))
  end

  # A row of four and a pad of two cannot share one mapping, so the event carries the
  # board and this module reads it. See `MyHiFi.Peripheral.PirateAudio`.
  # **A hold of the track buttons moves the level.** A row of four holds every control
  # on a short press already, and a hold of one of them held none, so the level costs
  # no control that a person had. See `MyHiFi.Output.Volume`.
  describe "a hold of the track buttons of the PiTFT" do
    setup do
      TwoCardOutput.use_it()
      :ok = MyHiFi.Player.select_output("rate48:CARD=first,DEV=0")
      start_supervised!(Volume)
      :ok = Volume.enable(true)
      :ok = Volume.set_percent(50)

      # The setup publishes on the topic that this test reads, so a test that refuses a
      # message would refuse one of these.
      flush()

      :ok
    end

    test "a hold of the forward button raises the level" do
      press(4, PiTft, :long)

      assert_receive %Player.VolumeChanged{percent: 55}, 5000
    end

    test "a hold of the back button lowers it" do
      press(2, PiTft, :long)

      assert_receive %Player.VolumeChanged{percent: 45}, 5000
    end

    # A level cannot leave the range, and a person holding a button at either end must
    # not see it wrap around.
    test "the level stops at the loudest and at silence" do
      :ok = Volume.set_percent(98)
      flush()
      press(4, PiTft, :long)
      assert_receive %Player.VolumeChanged{percent: 100}, 5000

      :ok = Volume.set_percent(2)
      flush()
      press(2, PiTft, :long)
      assert_receive %Player.VolumeChanged{percent: 0}, 5000
    end

    # A hold of the standby button means nothing on a stereo, and the Pirate Audio uses
    # it for standby itself.
    test "a hold of the standby button moves nothing" do
      press(1, PiTft, :long)

      refute_receive %Player.VolumeChanged{}, 200
    end

    test "a hold moves nothing while the control is off" do
      :ok = Volume.enable(false)
      flush()

      press(4, PiTft, :long)

      refute_receive %Player.VolumeChanged{percent: 55}, 200
    end
  end

  describe "the buttons of the Pirate Audio" do
    # The first button of the PiTFT is standby, and of this board it is play. A press of
    # one must never do what the other one does.
    test "the first button plays and pauses, and never enters standby" do
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      log =
        capture_log(fn ->
          press(1, MyHiFi.Peripheral.PirateAudio)
          Process.sleep(200)
        end)

      # The queue is empty, so a play can do nothing and says so.
      assert log =~ "The control did nothing"
      refute_receive %Player.Standby{}, 200
    end

    test "the second button asks for the track after this one" do
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      log =
        capture_log(fn ->
          press(2, MyHiFi.Peripheral.PirateAudio)
          Process.sleep(200)
        end)

      assert log =~ "The control did nothing"
      refute_receive %Player.Standby{}, 200
    end

    # Two buttons hold three controls, so the hold of the first is the third.
    test "a hold of the first button enters standby, and the next hold leaves it" do
      press(1, MyHiFi.Peripheral.PirateAudio, :long)
      assert_receive %Player.Standby{entered?: true}, 5000

      press(1, MyHiFi.Peripheral.PirateAudio, :long)
      assert_receive %Player.Standby{entered?: false}, 5000
    end

    # A board of four holds a button for standby and reads no hold at all.
    test "a hold of a button of the row of four does nothing" do
      press(1, PiTft, :long)
      Process.sleep(100)

      refute_receive %Player.Standby{}, 200
    end

    # This board holds two that answer, and the other two are broken.
    test "a third button does nothing, because this board holds no third" do
      press(3, MyHiFi.Peripheral.PirateAudio)
      Process.sleep(100)

      assert Process.alive?(Process.whereis(MyHiFi.DeviceUi))
      refute_receive %Player.Standby{}, 200
    end
  end
end
