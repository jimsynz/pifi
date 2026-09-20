defmodule PiFi.SpotifyTest do
  use PiFi.DataCase, async: false

  doctest PiFi.Spotify, import: true

  alias PiFi.Event
  alias PiFi.Event.Device, as: Events
  alias PiFi.Settings
  alias PiFi.Spotify
  alias PiFi.Test.NoCardOutput

  setup do
    on_exit(fn ->
      Spotify.enable(false)

      case Settings.fetch(Spotify.enabled_key()) do
        {:ok, setting} -> Settings.delete!(setting)
        {:error, _reason} -> :ok
      end
    end)

    :ok
  end

  describe "whether a person turned it on" do
    test "a device that no person changed holds it off" do
      refute Spotify.enabled?()
      refute Spotify.running?()
    end

    test "a person turns it on, and the answer stays" do
      assert :ok = Spotify.enable(true)
      assert Spotify.enabled?()
    end

    test "a person turns it off again" do
      Spotify.enable(true)

      assert :ok = Spotify.enable(false)

      refute Spotify.enabled?()
      refute Spotify.running?()
    end
  end

  # **librespot plays to a card, and it is given the name of one when it starts.** A
  # device with none has nothing to give it, and a daemon that started anyway would
  # write to whatever ALSA calls the default.
  describe "a device with no sound card" do
    test "it starts no daemon, and it says so rather than failing" do
      NoCardOutput.use_it()

      assert :ok = Spotify.enable(true)

      # The setting is what a person chose, and it stays chosen. The daemon starts
      # when a card arrives.
      assert Spotify.enabled?()
      refute Spotify.running?()
    end
  end

  # librespot reads its name and its card once, as arguments, so the only way to
  # change either is to start it again. See `PiFi.Spotify.Monitor`.
  describe "what librespot was told" do
    test "a restart of a daemon that is not running does nothing" do
      assert :ok = Spotify.restart()
      refute Spotify.running?()
    end

    test "the monitor watches the topic whether the daemon runs or not" do
      assert is_pid(Process.whereis(PiFi.Spotify.Monitor))

      Event.publish(:device, %Events.IdentityChanged{name: "Kitchen", splash_path: nil})
      Event.publish(:device, %Events.OutputChanged{devices: [], selected: nil, in_use: nil})

      # Nothing to restart, and nothing falls over for trying.
      assert eventually(fn -> Process.alive?(Process.whereis(PiFi.Spotify.Monitor)) end)
    end

    # The storage and the battery report on the same topic, and neither is an argument
    # that librespot was given.
    test "a report that is not one of its arguments is ignored" do
      monitor = Process.whereis(PiFi.Spotify.Monitor)

      Event.publish(:device, %Events.StorageChanged{
        path: "/root",
        total_bytes: 1,
        free_bytes: 1,
        used_bytes: 0,
        database_bytes: 0,
        full?: false
      })

      Process.sleep(50)

      assert Process.whereis(PiFi.Spotify.Monitor) == monitor
    end
  end

  defp eventually(check, attempts \\ 50)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(20)
      eventually(check, attempts - 1)
    end
  end
end
