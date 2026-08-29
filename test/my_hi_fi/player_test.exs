defmodule MyHiFi.PlayerTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Settings
  alias MyHiFi.Source.InternetRadio
  alias MyHiFi.Test.NoCardOutput
  alias MyHiFi.Test.Stations

  @keys ["last_item", "standby", "output_device"]

  defp station(overrides), do: Stations.create(overrides)

  defp clear_settings do
    for key <- @keys do
      case Settings.fetch(key) do
        {:ok, setting} -> Settings.delete!(setting)
        {:error, _reason} -> :ok
      end
    end
  end

  # `MyHiFi.Player` is one process for the whole node, and the settings are rows.
  # A test that restores a station therefore leaves both behind, so each test
  # starts from nothing selected.
  defp reset do
    clear_settings()
    MyHiFi.Player.stop()
    MyHiFi.Player.standby(false)
    clear_settings()
  end

  setup do
    reset()
    on_exit(&reset/0)
    :ok
  end

  describe "the standby state" do
    test "entering standby writes the state" do
      MyHiFi.Player.standby(true)

      assert {:ok, %{value: "true"}} = Settings.fetch("standby")

      MyHiFi.Player.standby(false)

      assert {:ok, %{value: "false"}} = Settings.fetch("standby")
    end

    test "leaving standby with nothing selected plays nothing" do
      MyHiFi.Player.standby(true)

      assert :ok = MyHiFi.Player.standby(false)
      assert %{playing?: false, item: nil} = MyHiFi.Player.state()
    end
  end

  describe "the last station" do
    test "a play that fails stores nothing" do
      # The play must fail on any machine, so this test holds an output that finds
      # no card. `MyHiFi.Output.Alsa` lists the cards of the machine, and a host
      # holds one.
      NoCardOutput.use_it()

      created = station(%{})

      assert {:error, _reason} = MyHiFi.Player.play(created)
      assert {:error, _reason} = Settings.fetch("last_item")
    end

    test "an item in the settings comes back as a selected station" do
      created = station(%{title: "RNZ Concert"})

      Settings.put!("last_item", created.id)

      state = restarted_state()

      assert state.source == InternetRadio
      assert state.item.title == "RNZ Concert"

      # A stereo that starts to play by itself after a power cut is a surprise, so
      # the station is selected only.
      assert state.playing? == false
    end

    test "the standby state comes back as well" do
      Settings.put!("standby", "true")

      assert restarted_state().standby? == true
    end

    test "a station that has left the table selects nothing" do
      Settings.put!("last_item", Ash.UUID.generate())

      assert restarted_state().item == nil
    end

    # A source that a person took out of use must not come back, and neither must one
    # that a later version of the firmware removed.
    test "an item of a source that is not in use selects nothing" do
      created = station(%{})
      Settings.put!("last_item", created.id)
      MyHiFi.Playback.enable_source(InternetRadio, false)

      assert restarted_state().item == nil

      MyHiFi.Playback.enable_source(InternetRadio, true)
    end

    test "a value that names no item at all selects nothing" do
      Settings.put!("last_item", "rubbish")

      assert restarted_state().item == nil
    end

    test "no settings at all selects nothing" do
      assert restarted_state().item == nil
      assert restarted_state().standby? == false
    end
  end

  # The player read its settings when the node started, so a test starts it again
  # through its own supervisor. That runs the same code that a boot runs.
  defp restarted_state do
    :ok = Supervisor.terminate_child(MyHiFi.Supervisor, MyHiFi.Player)
    {:ok, _pid} = Supervisor.restart_child(MyHiFi.Supervisor, MyHiFi.Player)

    MyHiFi.Player.state()
  end
end
