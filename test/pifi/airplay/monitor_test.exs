defmodule PiFi.AirPlay.MonitorTest do
  @moduledoc """
  The switch and the sessions, from the player's end.

  It is what makes AirPlay behave like every other source rather than like a listener
  off to one side: turning the source on opens the port, and a telephone starting to
  send makes this device play what it sends.
  """

  use PiFi.DataCase, async: false

  alias PiFi.AirPlay.Monitor
  alias PiFi.AirPlay.Server
  alias PiFi.Event.Source.EnabledChanged
  alias PiFi.Settings
  alias PiFi.Source

  setup do
    # **One monitor for the whole node**, so a session another test started is still the
    # current one here.
    if socket = Monitor.socket(), do: Monitor.stopped(socket)

    on_exit(fn ->
      PiFi.Player.stop()

      Server.enable(false)

      case Settings.fetch(Source.enabled_key(Source.AirPlay)) do
        {:ok, setting} -> Settings.delete!(setting)
        {:error, _reason} -> :ok
      end
    end)

    :ok
  end

  describe "the switch" do
    # **The setting is what a person changed, so the port has to catch up.** A switch
    # that said on over a port that never opened is the one disagreement that matters.
    test "turning the source on opens the port" do
      refute Server.running?()

      Source.enable(Source.AirPlay, true)

      assert eventually(fn -> Server.running?() end)
    end

    test "turning it off shuts the port" do
      Source.enable(Source.AirPlay, true)
      assert eventually(fn -> Server.running?() end)

      Source.enable(Source.AirPlay, false)

      assert eventually(fn -> not Server.running?() end)
    end

    # Every source publishes on the same topic, and none of the others is this one.
    #
    # **The event is published rather than the source enabled.** Turning Spotify on for
    # real starts librespot and leaves a setting behind for whatever test runs next,
    # which is a side effect this has no business having to test a filter.
    test "another source being enabled changes nothing here" do
      PiFi.Event.publish(:source, %EnabledChanged{source: Source.Spotify, enabled?: true})

      refute eventually(fn -> Server.running?() end, 10)
    end
  end

  describe "a session" do
    test "nothing is streaming to begin with" do
      assert Monitor.socket() == nil
    end

    test "a stream that starts is the one the pipeline is given" do
      socket = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(socket, :kill) end)

      Monitor.started(socket)

      assert eventually(fn -> Monitor.socket() == socket end)
    end

    test "a stream that ends leaves nothing for the pipeline" do
      socket = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(socket, :kill) end)

      Monitor.started(socket)
      assert eventually(fn -> Monitor.socket() == socket end)

      Monitor.stopped(socket)

      assert eventually(fn -> Monitor.socket() == nil end)
    end

    # **A telephone that was never the one playing must not stop the music.** A
    # `TEARDOWN` arrives from any connection that ends, and one from a session that was
    # not streaming would otherwise take a person's audio away.
    test "a teardown from another session leaves the current one alone" do
      playing = spawn(fn -> Process.sleep(:infinity) end)
      other = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> for pid <- [playing, other], do: Process.exit(pid, :kill) end)

      Monitor.started(playing)
      assert eventually(fn -> Monitor.socket() == playing end)

      Monitor.stopped(other)

      refute eventually(fn -> Monitor.socket() == nil end, 10)
      assert Monitor.socket() == playing
    end
  end

  defp eventually(check, attempts \\ 100)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(10)
      eventually(check, attempts - 1)
    end
  end
end
