defmodule MyHiFi.Output.VolumeTest do
  # It writes settings and it reads the player, so two of these cannot run at once.
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Event
  alias MyHiFi.Event.Device, as: DeviceEvents
  alias MyHiFi.Event.Player, as: Events
  alias MyHiFi.Output.Volume
  alias MyHiFi.Settings
  alias MyHiFi.Test.TwoCardOutput

  @first "rate48:CARD=first,DEV=0"

  setup do
    TwoCardOutput.use_it()
    :ok = MyHiFi.Player.select_output(@first)

    :ok
  end

  describe "the control is off until a person turns it on" do
    # A stereo has always had its level on the amplifier, and a DAC that attenuates in
    # the digital domain throws bits away to do it.
    test "a device that no person set holds the control off and the card at 0 dB" do
      start_volume()

      assert %{enabled?: false, percent: 100} = Volume.state()
      assert TwoCardOutput.writes() == [{@first, 100}]
    end

    # The number goes to the settings either way, so a person who turns the control on
    # gets the number that they chose before.
    test "a level that a person sets while it is off writes no card" do
      start_volume()
      TwoCardOutput.use_it()

      assert {:error, :not_enabled} = Volume.set_percent(40)
      assert TwoCardOutput.writes() == []
      assert %{percent: 40} = Volume.state()
    end
  end

  describe "a control that a person turned on" do
    setup do
      start_volume()
      :ok = Volume.enable(true)
      TwoCardOutput.use_it()

      :ok
    end

    test "a level that a person sets reaches the card" do
      assert :ok = Volume.set_percent(40)

      assert TwoCardOutput.writes() == [{@first, 40}]
      assert %{percent: 40, enabled?: true} = Volume.state()
    end

    test "it says that the card holds a level" do
      assert %{supported?: true} = Volume.state()
    end

    test "a level outside the range is refused, and it writes nothing" do
      assert {:error, :out_of_range} = Volume.set_percent(101)
      assert {:error, :out_of_range} = Volume.set_percent(-1)
      assert TwoCardOutput.writes() == []
    end

    test "0 is a level and not a refusal, because a person may silence the device" do
      assert :ok = Volume.set_percent(0)
      assert TwoCardOutput.writes() == [{@first, 0}]
    end

    # **The hardware forgets the level at each boot, and a card that a person plugs in
    # has never been told it.**
    test "a card that arrives is told the level" do
      :ok = Volume.set_percent(40)
      TwoCardOutput.use_it()

      Event.publish(:device, %DeviceEvents.OutputChanged{
        devices: TwoCardOutput.devices!(),
        selected: @first,
        in_use: @first
      })

      assert eventually(fn -> TwoCardOutput.writes() == [{@first, 40}] end)
    end

    # A person who attenuates and then turns the control off would otherwise leave a
    # card that plays quietly with nothing that can raise it.
    test "turning the control off returns the card to 0 dB" do
      :ok = Volume.set_percent(30)
      TwoCardOutput.use_it()

      :ok = Volume.enable(false)

      assert TwoCardOutput.writes() == [{@first, 100}]
    end

    # The number stays, so a person who turns it on again hears what they chose.
    test "the level that a person chose survives the control going off and on" do
      :ok = Volume.set_percent(30)
      :ok = Volume.enable(false)
      :ok = Volume.enable(true)

      assert %{percent: 30, enabled?: true} = Volume.state()
    end
  end

  describe "a card that holds no level" do
    # **A DAC of a fixed output is normal**, and the PCM5102A of a Pirate Audio board
    # is one. A person with that card sets the level on their amplifier.
    test "it says that the card holds none, whatever a person chose" do
      :ok = MyHiFi.Player.select_output("rate48:CARD=second,DEV=0")
      start_volume()
      :ok = Volume.enable(true)

      assert %{supported?: false, enabled?: true} = Volume.state()
    end

    test "a level that the card refuses stops nothing" do
      :ok = MyHiFi.Player.select_output("rate48:CARD=second,DEV=0")
      start_volume()
      :ok = Volume.enable(true)

      assert :ok = Volume.set_percent(40)
      assert %{percent: 40} = Volume.state()
    end
  end

  # **A page that reads the level must never wait for the player.** The player stops one
  # pipeline and starts the next inside the call that it answers, so a change of track
  # holds it for seconds. This read asked it for the card in use, so every page of the
  # web interface waited behind that work and then logged
  # `The volume did not say what it is: {:timeout, ...}`. See #157.
  describe "a player that is busy" do
    test "the level answers while the player answers nothing" do
      start_volume()
      :ok = Volume.enable(true)
      :ok = Volume.set_percent(40)

      :sys.suspend(MyHiFi.Player)

      try do
        answer = Task.async(fn -> Volume.state() end)

        assert %{percent: 40, enabled?: true, supported?: true} = Task.await(answer, 500)
      after
        :sys.resume(MyHiFi.Player)
      end
    end
  end

  # The card in use changes when a person chooses another one, and no uevent says so.
  # `MyHiFi.Output.Volume` keeps the card that this event names, so a firmware that
  # published it for a card that arrives alone left that process with the old one.
  describe "a person who chooses another card" do
    # The second card of `MyHiFi.Test.TwoCardOutput` holds no level, in the way that the
    # PCM5102A of a Pirate Audio board holds none, so this reads as the control going
    # away.
    test "the control follows the card that the person chose" do
      start_volume()
      :ok = Volume.enable(true)
      :ok = Volume.set_percent(40)

      assert %{supported?: true} = Volume.state()

      :ok = MyHiFi.Player.select_output("rate48:CARD=second,DEV=0")

      assert eventually(fn -> Volume.state().supported? == false end)
    end
  end

  describe "what it publishes" do
    setup do
      start_volume()
      Event.subscribe(:player)

      :ok
    end

    test "a level that moves reaches the rest of the firmware" do
      :ok = Volume.enable(true)

      assert_receive %Events.VolumeChanged{enabled?: true, percent: 100, supported?: true}

      :ok = Volume.set_percent(40)

      assert_receive %Events.VolumeChanged{percent: 40, enabled?: true}
    end

    test "the control going off says so as well" do
      :ok = Volume.enable(true)
      :ok = Volume.enable(false)

      assert_receive %Events.VolumeChanged{enabled?: false}
    end
  end

  describe "the settings" do
    test "the level and the control both survive a restart" do
      Settings.put!(Volume.percent_key(), "35")
      Settings.put!(Volume.enabled_key(), "true")

      start_volume()

      assert %{percent: 35, enabled?: true} = Volume.state()
    end

    # A row that holds something that is not a number is a row that no part of this
    # firmware writes, and the loudest level is better than a process that will not
    # start.
    test "a row that holds no number gives the loudest level" do
      Settings.put!(Volume.percent_key(), "loud")

      start_volume()

      assert %{percent: 100} = Volume.state()
    end
  end

  # **`start_supervised!/1` returns before `handle_continue/2` runs**, and that callback
  # writes the level of the boot. A read of the state waits for it, because a call
  # queues behind the continue, so a test that clears the writes after this clears them
  # after that write and not before it.
  defp start_volume do
    pid = start_supervised!(Volume)
    Volume.state()

    pid
  end

  defp eventually(check, attempts \\ 20) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(25) && eventually(check, attempts - 1)
    end
  end
end
