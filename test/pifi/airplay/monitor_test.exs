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
  alias PiFi.Playback
  alias PiFi.Settings
  alias PiFi.Source

  setup do
    # **One monitor and one listener for the whole node**, so whatever another test left
    # behind is still here. The setup establishes what each test assumes rather than
    # trusting the previous one's `on_exit` to have finished: a test that refutes the
    # listener is running fails if it was already running when it started, and that is
    # how it failed in CI.
    if socket = Monitor.socket(), do: Monitor.stopped(socket)

    Server.enable(false)
    assert eventually(fn -> not Server.running?() end)

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

      Monitor.started(socket, :realtime)

      assert eventually(fn -> Monitor.socket() == socket end)
    end

    test "a stream that ends leaves nothing for the pipeline" do
      socket = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(socket, :kill) end)

      Monitor.started(socket, :realtime)
      assert eventually(fn -> Monitor.socket() == socket end)

      Monitor.stopped(socket)

      assert eventually(fn -> Monitor.socket() == nil end)
    end

    # **A telephone that goes away sends no `TEARDOWN`.** Its RTSP connection ends, the
    # audio socket is linked to it and dies with it, and the pid left here would go to
    # the next pipeline, which would ask a process that is not there.
    test "a socket that dies leaves nothing for the pipeline" do
      socket = spawn(fn -> Process.sleep(:infinity) end)

      Monitor.started(socket, :realtime)
      assert eventually(fn -> Monitor.socket() == socket end)

      Process.exit(socket, :kill)

      assert eventually(fn -> Monitor.socket() == nil end)
    end

    # The watch belongs to the session that is streaming now. A `:DOWN` of one that
    # ended already would otherwise stop the stream that replaced it.
    test "a socket that died before this one started stops nothing" do
      gone = spawn(fn -> Process.sleep(:infinity) end)
      playing = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(playing, :kill) end)

      Monitor.started(gone, :realtime)
      assert eventually(fn -> Monitor.socket() == gone end)

      Monitor.started(playing, :realtime)
      assert eventually(fn -> Monitor.socket() == playing end)

      Process.exit(gone, :kill)

      refute eventually(fn -> Monitor.socket() == nil end, 10)
      assert Monitor.socket() == playing
    end

    # **A telephone that was never the one playing must not stop the music.** A
    # **A telephone that was never the one playing must not stop the music.** A
    # `TEARDOWN` arrives from any connection that ends, and one from a session that was
    # not streaming would otherwise take a person's audio away.
    test "a teardown from another session leaves the current one alone" do
      playing = spawn(fn -> Process.sleep(:infinity) end)
      other = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> for pid <- [playing, other], do: Process.exit(pid, :kill) end)

      Monitor.started(playing, :realtime)
      assert eventually(fn -> Monitor.socket() == playing end)

      Monitor.stopped(other)

      refute eventually(fn -> Monitor.socket() == nil end, 10)
      assert Monitor.socket() == playing
    end
  end

  # **A person who casts presses nothing on this device**, so the only thing that can
  # move the source of the device is the player taking the stream. The top row of the
  # faceplate reads the player, which is why nothing here writes a setting of its own.
  # See `PiFiWeb.Browsing`.
  describe "the source of the device" do
    test "it becomes AirPlay when a telephone starts a stream" do
      Source.enable(Source.AirPlay, true)

      socket = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(socket, :kill) end)

      Monitor.started(socket, :realtime)

      assert eventually(fn -> Playback.state!().source == Source.AirPlay end)
    end

    # A play of a source that a person put out of use is refused, and the device must
    # not then name a source that plays nothing.
    test "a stream of a source that is out of use plays nothing" do
      Source.enable(Source.AirPlay, false)

      socket = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(socket, :kill) end)

      Monitor.started(socket, :realtime)

      refute eventually(fn -> Playback.state!().source == Source.AirPlay end, 10)
    end
  end

  # **A telephone sends what is playing whether this device took its session or not.**
  # The words and the picture must not land on a person's radio because a phone in the
  # house said something.
  describe "what a telephone says is playing" do
    test "a sender whose session was never taken writes nothing" do
      PiFi.Event.subscribe(:player)

      Monitor.now_playing(%{
        title: "A Song",
        artist: "Someone",
        album: nil,
        artwork: nil,
        artwork_type: nil
      })

      refute_receive %PiFi.Event.Player.MetadataChanged{}, 200
    end
  end

  # **The slider of a telephone only reaches a device that a person gave it to.** A
  # handset in the house that this device never took a session from must not turn a
  # person's radio down.
  describe "the volume a telephone asks for" do
    test "a sender whose session was never taken changes nothing" do
      before = Playback.volume!().percent

      Monitor.volume(trunc(max(before - 10, 0)))

      refute eventually(fn -> Playback.volume!().percent != before end, 10)
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
