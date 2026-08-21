defmodule MyHiFi.PlayerTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Radio
  alias MyHiFi.Settings
  alias MyHiFi.Source.InternetRadio

  @keys ["last_source", "last_ref", "standby", "output_device"]

  defp station(overrides) do
    defaults = %{
      remote_id: "remote-#{System.unique_integer([:positive])}",
      title: "Station #{System.unique_integer([:positive])}",
      stream_url: "http://example.test/stream.mp3",
      codec: "MP3",
      bitrate: 128,
      hls?: false,
      country_code: "NZ",
      tags: ["news"],
      click_count: 0
    }

    Radio.upsert_station_from_remote!(Map.merge(defaults, overrides))
  end

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
      assert %{playing?: false, track: nil} = MyHiFi.Player.state()
    end
  end

  describe "the last station" do
    test "a play that fails stores nothing" do
      # No USB DAC is present on a host, so a play cannot succeed here.
      created = station(%{})

      assert {:error, _reason} = MyHiFi.Player.play(InternetRadio, {:station, created.id})
      assert {:error, _reason} = Settings.fetch("last_ref")
    end

    test "a name in the settings comes back as a selected station" do
      created = station(%{title: "RNZ Concert"})

      Settings.put!("last_source", inspect(InternetRadio))
      Settings.put!("last_ref", "station:" <> created.id)

      state = restarted_state()

      assert state.source == InternetRadio
      assert state.track.title == "RNZ Concert"

      # Section 9 asks for silence at a start, so the station is selected only.
      assert state.playing? == false
    end

    test "the standby state comes back as well" do
      Settings.put!("standby", "true")

      assert restarted_state().standby? == true
    end

    test "a station that has left the table selects nothing" do
      Settings.put!("last_source", inspect(InternetRadio))
      Settings.put!("last_ref", "station:" <> Ash.UUID.generate())

      assert restarted_state().track == nil
    end

    test "a name that no source of this firmware wrote selects nothing" do
      created = station(%{})

      Settings.put!("last_source", "MyHiFi.Source.SomethingRemoved")
      Settings.put!("last_ref", "station:" <> created.id)

      assert restarted_state().track == nil
    end

    test "a ref that the source cannot read selects nothing" do
      Settings.put!("last_source", inspect(InternetRadio))
      Settings.put!("last_ref", "rubbish")

      assert restarted_state().track == nil
    end

    test "no settings at all selects nothing" do
      assert restarted_state().track == nil
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
