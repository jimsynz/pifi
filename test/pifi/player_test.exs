defmodule PiFi.PlayerTest do
  use PiFi.DataCase, async: false

  alias PiFi.Event
  alias PiFi.Event.Player, as: Events
  alias PiFi.Playback
  alias PiFi.Settings
  alias PiFi.Source.InternetRadio
  alias PiFi.Test.NoCardOutput
  alias PiFi.Test.Stations

  @keys ["standby", "output_device"]

  defp station(overrides), do: Stations.create(overrides)

  defp clear_settings do
    for key <- @keys do
      case Settings.fetch(key) do
        {:ok, setting} -> Settings.delete!(setting)
        {:error, _reason} -> :ok
      end
    end
  end

  # `PiFi.Player` is one process for the whole node, and the queue and the settings
  # are rows. A test that restores a station therefore leaves all three behind, so
  # each test starts from nothing selected.
  defp reset do
    clear_settings()
    Playback.clear_queue!()
    PiFi.Player.stop()
    PiFi.Player.standby(false)
    clear_settings()
  end

  setup do
    reset()
    on_exit(&reset/0)
    :ok
  end

  describe "the standby state" do
    test "entering standby writes the state" do
      PiFi.Player.standby(true)

      assert {:ok, %{value: "true"}} = Settings.fetch("standby")

      PiFi.Player.standby(false)

      assert {:ok, %{value: "false"}} = Settings.fetch("standby")
    end

    test "leaving standby with nothing selected plays nothing" do
      PiFi.Player.standby(true)

      assert :ok = PiFi.Player.standby(false)
      assert %{playing?: false, item: nil} = PiFi.Player.state()
    end
  end

  # **The queue is what the device remembers.** It is in SQLite, so a reboot and a
  # firmware upgrade both leave it where it was, and the marked row of it is the track
  # that comes back. See `PiFi.Playback.Queue`.
  describe "the last station" do
    test "a play that fails leaves the queue where the person put it" do
      # The play must fail on any machine, so this test holds an output that finds
      # no card. `PiFi.Output.Alsa` lists the cards of the machine, and a host
      # holds one.
      NoCardOutput.use_it()

      created = station(%{title: "RNZ Concert"})

      # A play answers before it starts, so the fault arrives on the topic. See
      # `PiFi.Player.handle_call({:play, _}, _, _)`.
      Event.subscribe(:player)

      assert {:ok, :ok} = Playback.play([created.id])
      assert_receive %Events.Failed{reason: :no_output_device}, 2000

      assert restarted_state().item.title == "RNZ Concert"
    end

    test "the marked row of the queue comes back as a selected station" do
      created = station(%{title: "RNZ Concert"})

      Playback.replace_queue!([created.id])

      state = restarted_state()

      assert state.source == InternetRadio
      assert state.item.title == "RNZ Concert"

      # A stereo that starts to play by itself after a power cut is a surprise, so
      # the station is selected only.
      assert state.playing? == false
    end

    # A queue holds the whole list that a person pressed, so next and previous work
    # after a restart and not only after a play.
    test "the rest of the queue comes back with it" do
      one = station(%{title: "RNZ National"})
      two = station(%{title: "RNZ Concert"})

      Playback.replace_queue!([one.id, two.id], %{playing_index: 1})

      assert restarted_state().item.title == "RNZ Concert"
      assert Enum.map(Playback.queue!(), & &1.item_id) == [one.id, two.id]
    end

    test "the standby state comes back as well" do
      Settings.put!("standby", "true")

      assert restarted_state().standby? == true
    end

    # A source that a person took out of use must not come back, and neither must one
    # that a later version of the firmware removed.
    test "an item of a source that is not in use selects nothing" do
      created = station(%{})
      Playback.replace_queue!([created.id])
      Playback.enable_source(InternetRadio, false)

      assert restarted_state().item == nil

      Playback.enable_source(InternetRadio, true)
    end

    test "a queue with no marked row selects nothing" do
      created = station(%{})
      Playback.append_to_queue!([created.id])

      assert restarted_state().item == nil
    end

    test "an empty queue selects nothing" do
      assert restarted_state().item == nil
      assert restarted_state().standby? == false
    end
  end

  # The player read its settings when the node started, so a test starts it again
  # through its own supervisor. That runs the same code that a boot runs.
  defp restarted_state do
    :ok = Supervisor.terminate_child(PiFi.Supervisor, PiFi.Player)
    {:ok, _pid} = Supervisor.restart_child(PiFi.Supervisor, PiFi.Player)

    PiFi.Player.state()
  end
end
