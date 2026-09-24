defmodule PiFi.PlayerOutputTest do
  @moduledoc """
  What the player does when the output it was playing through goes away.

  A Bluetooth headset arrives and goes while the firmware runs, and a card does not, so
  this is the case that Bluetooth brought. A board showed both halves of it going wrong:
  turning a headset off put the music out loud on the stereo, and turning it back on
  left it there while the settings page still said the headset.
  """

  use PiFi.DataCase, async: false

  alias PiFi.Event
  alias PiFi.Event.Device, as: DeviceEvents
  alias PiFi.Event.Player, as: Events
  alias PiFi.Playback
  alias PiFi.Player
  alias PiFi.Test.PlayingPipeline
  alias PiFi.Test.SilentOutput
  alias PiFi.Test.Stations

  setup do
    PlayingPipeline.use_it()
    SilentOutput.use_it()
    Event.subscribe(:player)
    Event.subscribe(:device)

    on_exit(fn ->
      Player.stop()
      Player.standby(false)
      Playback.clear_queue!()
      Application.delete_env(:pifi, :silent_output_devices)

      for key <- ["last_item", "standby", "output_device"] do
        case PiFi.Settings.fetch(key) do
          {:ok, setting} -> PiFi.Settings.delete!(setting)
          {:error, _reason} -> :ok
        end
      end
    end)

    :ok
  end

  defp playing do
    station = Stations.create(%{title: "A station"})

    assert {:ok, :ok} = Playback.play([station.id], %{playing_index: 0})
    assert_receive %Events.Started{}, 2000

    station
  end

  defp chose_the_silent_card do
    assert {:ok, :ok} = Playback.select_output(SilentOutput.device!().id)
  end

  describe "a device that goes while something plays" do
    # **Falling back would put the music out loud.** `PiFi.Player` uses the first device
    # it can find when the chosen one is absent, which is right for a card that was
    # never there and wrong for headphones somebody just took off.
    test "pauses rather than moving the audio somewhere else" do
      chose_the_silent_card()
      playing()

      SilentOutput.vanish()
      Player.outputs_changed()

      assert_receive %Events.Paused{}, 2000
      assert PiFi.Player.state().paused?
    end

    test "says the list of outputs changed, so a page stops showing what was true before" do
      chose_the_silent_card()
      playing()

      SilentOutput.vanish()
      Player.outputs_changed()

      assert_receive %DeviceEvents.OutputChanged{devices: [], selected: "silent"}, 2000
    end

    test "keeps the track, because a pause is not a stop" do
      chose_the_silent_card()
      station = playing()

      SilentOutput.vanish()
      Player.outputs_changed()

      assert_receive %Events.Paused{}, 2000
      assert PiFi.Player.state().item.id == station.id
    end
  end

  describe "a device that comes back" do
    test "plays again by itself" do
      chose_the_silent_card()
      playing()

      SilentOutput.vanish()
      Player.outputs_changed()
      assert_receive %Events.Paused{}, 2000

      SilentOutput.appear()
      Player.outputs_changed()

      assert_receive %Events.Started{}, 2000
      refute PiFi.Player.state().paused?
    end

    # A person who paused before the headset went is a person who wanted it paused.
    # Only a pause this made is one this undoes.
    test "leaves a pause that a person asked for alone" do
      chose_the_silent_card()
      playing()

      assert :ok = Player.pause(true)
      assert_receive %Events.Paused{}, 2000

      SilentOutput.appear()
      Player.outputs_changed()

      refute_receive %Events.Started{}, 500
      assert PiFi.Player.state().paused?
    end
  end

  describe "a person who chose nothing" do
    # The fallback is for them, and there is no device of theirs to lose.
    test "is left to the fallback and never paused" do
      playing()

      SilentOutput.vanish()
      Player.outputs_changed()

      refute_receive %Events.Paused{}, 500
      refute PiFi.Player.state().paused?
    end
  end

  describe "when nothing is playing" do
    test "a device going away changes nothing but the event" do
      chose_the_silent_card()

      SilentOutput.vanish()
      Player.outputs_changed()

      assert_receive %DeviceEvents.OutputChanged{}, 2000
      refute_receive %Events.Paused{}, 500
    end
  end

  # **Something has to go looking, and this says whether it is worth it.**
  # `PiFi.Bluetooth.Watcher` reconnects a headset a person switched off, and a radio that
  # reached for a device nobody is waiting on would be poking at a headset in a drawer.
  describe "what is waiting for an output" do
    test "nothing is waiting when nothing was lost" do
      chose_the_silent_card()
      playing()

      assert Player.waiting_for_output() == nil
    end

    test "the chosen output is waiting once it goes" do
      chose_the_silent_card()
      playing()

      SilentOutput.vanish()
      Player.outputs_changed()
      assert_receive %Events.Paused{}, 2000

      assert Player.waiting_for_output() == SilentOutput.device!().id
    end

    # **A person who put the device to sleep is not waiting for music**, whatever is
    # paused behind it.
    test "standby is nobody waiting" do
      chose_the_silent_card()
      playing()

      SilentOutput.vanish()
      Player.outputs_changed()
      assert_receive %Events.Paused{}, 2000

      Player.standby(true)

      assert Player.waiting_for_output() == nil
    end

    test "a person who paused on purpose is not waiting either" do
      chose_the_silent_card()
      playing()

      assert :ok = Player.pause(true)
      assert_receive %Events.Paused{}, 2000

      assert Player.waiting_for_output() == nil
    end

    test "nothing is waiting once the output comes back" do
      chose_the_silent_card()
      playing()

      SilentOutput.vanish()
      Player.outputs_changed()
      assert_receive %Events.Paused{}, 2000

      SilentOutput.appear()
      Player.outputs_changed()
      assert_receive %Events.Started{}, 2000

      assert Player.waiting_for_output() == nil
    end

    # A stop is a person saying they are finished with it.
    test "a stop clears what was waiting" do
      chose_the_silent_card()
      playing()

      SilentOutput.vanish()
      Player.outputs_changed()
      assert_receive %Events.Paused{}, 2000

      Player.stop()

      assert Player.waiting_for_output() == nil
    end
  end
end
