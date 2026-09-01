defmodule MyHiFi.DeviceUiTest do
  # It reads the player, which one process holds for the whole firmware.
  use MyHiFi.DataCase, async: false

  import ExUnit.CaptureLog

  alias MyHiFi.Event
  alias MyHiFi.Event.Input
  alias MyHiFi.Event.Player
  alias MyHiFi.Playback

  setup do
    # `MyHiFi.Application` starts none of these in the test environment, so each test
    # holds one of its own and no test inherits a listener that it did not ask for. The
    # name is the one that the firmware uses, because these tests read it back.
    start_supervised!(MyHiFi.DeviceUi)

    :ok = Event.subscribe(:player)
    on_exit(fn -> Playback.standby(false) end)

    :ok
  end

  defp press(button, peripheral \\ MyHiFi.Peripheral.PiTft, hold \\ :short) do
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

  test "an event of the input topic that it cannot read does nothing" do
    Event.publish(:input, %URI{})
    Process.sleep(100)

    assert Process.alive?(Process.whereis(MyHiFi.DeviceUi))
  end

  # A row of four and a pad of two cannot share one mapping, so the event carries the
  # board and this module reads it. See `MyHiFi.Peripheral.PirateAudio`.
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
      press(1, MyHiFi.Peripheral.PiTft, :long)
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
