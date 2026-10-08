defmodule PiFi.AirPlay.Monitor do
  @moduledoc """
  Turns a sender starting and stopping into the player playing and stopping.

  Two jobs, and they are the same job from different ends. It follows the switch, so
  turning the source on opens the port and turning it off shuts it; and it follows the
  sessions, so a telephone that starts sending makes this device play what it sends.

  `PiFi.Spotify.Monitor` does the same for librespot, and the shape is deliberately the
  same: a push input is a telephone deciding what plays, and the player should not have
  to know which protocol carried it.

  ## The switch leads and the listener follows, but not silently

  A source is enabled by writing a setting, so the setting is what a person changed and
  the port has to catch up. **A port another program holds would otherwise leave a
  person looking at a switch that says on, with nothing listening.** So a listener that
  will not start puts the switch back and says why, which keeps the two from disagreeing
  in the one direction that matters.

  ## Which session is current, and why nothing carries it

  `PiFi.Source.AirPlay.resolve/1` has no socket to give: a session lasts as long as one
  telephone stays connected, and `PiFi.Player` builds its pipeline again whenever the
  output changes. A pid put into a playable would be dead by the time the second
  pipeline used it. So the playable says `:airplay` and the pipeline asks `socket/0`
  at the moment it builds.

  ## Only a stream this device is playing may stop it

  A `TEARDOWN` from a telephone that was never the one playing must not take a person's
  music away — the same care `PiFi.Spotify.Monitor` takes about librespot closing its
  sink while somebody is listening to the radio.

  ## A session ends in two ways, and only one of them is polite

  A telephone that is finished sends `TEARDOWN`, and `PiFi.AirPlay.Router` passes that
  on as `stopped/1`. **A telephone that goes away sends nothing at all.** Its RTSP
  connection ends, and `PiFi.AirPlay.Session` links its sockets to that connection, so
  the audio socket dies with it and nothing says so.

  So this watches the socket as well as listening for the word. Without that the pid of
  a session that ended stays here, `socket/0` hands it to the next pipeline, and
  `PiFi.AirPlay.PlaybackSource` asks a process that is not there. A board at
  192.168.3.142 did exactly that on 2026-10-08.
  """

  use GenServer

  alias PiFi.AirPlay.NowPlaying
  alias PiFi.AirPlay.Server
  alias PiFi.Event.Source.EnabledChanged
  alias PiFi.Playback
  alias PiFi.Source.AirPlay

  require Logger

  # The table that `stream/0` reads. See that function for why it is not a call.
  @streaming :pifi_airplay_stream

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @doc """
  Note that a sender began a stream, and start playing it.

  The socket is the one `PiFi.AirPlay.Session` opened for that sender, and `kind` says
  which of the two it is. A realtime session gives raw samples, because
  `PiFi.AirPlay.PlaybackSource` decodes the ALAC itself; a buffered one gives AAC for
  the decoder of the pipeline. `PiFi.Source.AirPlay.resolve/1` reads the kind from
  here, because a playable is built after the session is.
  """
  @spec started(pid(), :realtime | :buffered) :: :ok
  def started(socket, kind), do: GenServer.cast(__MODULE__, {:started, socket, kind})

  @doc "Note that the stream ended, and stop playing it."
  @spec stopped(pid()) :: :ok
  def stopped(socket), do: GenServer.cast(__MODULE__, {:stopped, socket})

  @doc """
  Note that the sender paused, which `SETRATEANCHORTIME` says with a rate of nothing.

  **A pause is not a stop.** The session stays open and the telephone keeps its place,
  so this pauses the player rather than clearing the track, and a rate of one plays it
  again. See `PiFi.AirPlay.Router`.
  """
  @spec paused() :: :ok
  def paused, do: GenServer.cast(__MODULE__, {:rate, :paused})

  @doc "Note that the sender started again, which is a rate of one."
  @spec resumed() :: :ok
  def resumed, do: GenServer.cast(__MODULE__, {:rate, :playing})

  @doc """
  Note what the sender says is playing, so the screens and the pages draw it.

  See `PiFi.AirPlay.NowPlaying` for where the message comes from and what shape it is.
  """
  @spec now_playing(NowPlaying.t()) :: :ok
  def now_playing(playing), do: GenServer.cast(__MODULE__, {:now_playing, playing})

  @doc """
  Note the level that the sender asked for, as a percentage.

  See `PiFi.AirPlay.Parameters` for where the number comes from and what it meant
  before it was a percentage.
  """
  @spec volume(0..100) :: :ok
  def volume(percent), do: GenServer.cast(__MODULE__, {:volume, percent})

  @doc "The socket of the session that is streaming now, if one is."
  @spec socket() :: pid() | nil
  def socket do
    case stream() do
      %{socket: socket} -> socket
      nil -> nil
    end
  end

  @doc """
  The session that is streaming now, as `%{socket: pid, kind: kind}`, or `nil`.

  `PiFi.Player.Pipeline` builds the source from this and `PiFi.Source.AirPlay.resolve/1`
  reads the kind, and **both of those run inside a continue of `PiFi.Player`**. So this
  reads a table rather than asking this process: a call would be waiting on a process
  that is itself waiting on the player, which is a deadlock that only a timeout ends.
  `PiFi.Player.status/0` is the same arrangement for the same reason.
  """
  @spec stream() :: %{socket: pid(), kind: :realtime | :buffered} | nil
  def stream do
    case :ets.whereis(@streaming) do
      :undefined -> nil
      table -> streaming(table)
    end
  end

  defp streaming(table) do
    case :ets.lookup(table, :stream) do
      [{:stream, stream}] -> stream
      [] -> nil
    end
  end

  @doc false
  @impl GenServer
  def init(_options) do
    PiFi.Event.subscribe(:source)

    :ets.new(@streaming, [:named_table, :protected, :set, read_concurrency: true])

    {:ok, %{socket: nil, kind: nil, watch: nil}}
  end

  @doc false
  @impl GenServer
  # **The session is noted before the player is asked to play it.** `PiFi.Player`
  # answers a play at once and builds its pipeline in a continue, and that continue
  # asks `stream/0` — so a session stored after the call is one the pipeline can find
  # missing. It only ever worked because the player was slow.
  def handle_cast({:started, socket, kind}, state) do
    Logger.info("An AirPlay sender started a #{kind} stream on #{inspect(socket)}.")

    state = noted(%{watching(state, socket) | socket: socket, kind: kind})

    case PiFi.Player.play(AirPlay.item()) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("An AirPlay stream did not play: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  # A sender that was not the one playing has nothing to stop.
  def handle_cast({:stopped, socket}, %{socket: socket} = state) do
    Logger.info("The AirPlay stream on #{inspect(socket)} ended.")

    if playing?(), do: PiFi.Player.stop()

    {:noreply, noted(%{watching(state, nil) | socket: nil, kind: nil})}
  end

  def handle_cast({:stopped, _other}, state), do: {:noreply, state}

  # **A telephone keeps sending these whether this device is playing it or not.** One
  # whose session was never taken must not write its track over a person's radio.
  def handle_cast({:now_playing, _playing}, %{socket: nil} = state), do: {:noreply, state}

  def handle_cast({:now_playing, playing}, state) do
    if playing?(), do: PiFi.Player.metadata(told(playing))

    {:noreply, state}
  end

  def handle_cast({:volume, _percent}, %{socket: nil} = state), do: {:noreply, state}

  # **The slider of a telephone only reaches a device that a person gave it to.** The
  # control is off until somebody turns it on — a stereo whose amplifier holds the
  # level is one where a telephone turning it down does nothing a person asked for — so
  # this reads the setting and leaves the card alone when the answer is no.
  #
  # `PiFi.Output.Volume.set_percent/2` keeps the number for a control that is off, so
  # that a card with a mixer arriving later plays at the level a person chose. A
  # telephone must not write that number: a person who turns the control on afterwards
  # would find their device at whatever a visitor's handset last said.
  def handle_cast({:volume, percent}, state) do
    if playing?() and volume_enabled?(), do: Playback.set_volume!(percent)

    {:noreply, state}
  end

  # A rate from a telephone that is not the one playing is a telephone whose session
  # this device never took, and it must not pause a person's music.
  def handle_cast({:rate, _rate}, %{socket: nil} = state), do: {:noreply, state}

  def handle_cast({:rate, rate}, state) do
    if playing?(), do: follow(rate)

    {:noreply, state}
  end

  # **The socket of the session that is playing has gone.** The reason says which of the
  # endings it was, and it is the one fact a log of a session that stopped by itself
  # does not otherwise carry. The rest of the work is the work of a `TEARDOWN`, so this
  # says so in the one place that does it.
  @doc false
  @impl GenServer
  def handle_info({:DOWN, watch, :process, socket, reason}, %{watch: watch} = state) do
    Logger.info("The AirPlay socket #{inspect(socket)} went: #{inspect(reason)}")

    handle_cast({:stopped, socket}, %{state | watch: nil})
  end

  def handle_info(%EnabledChanged{source: AirPlay, enabled?: true}, state) do
    case Server.enable(true) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("AirPlay did not start: #{inspect(reason)}")

        PiFi.Source.enable(AirPlay, false)
    end

    {:noreply, state}
  end

  def handle_info(%EnabledChanged{source: AirPlay, enabled?: false}, state) do
    Server.enable(false)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The one place that writes the table, so a reader cannot see a session this process
  # no longer holds.
  defp noted(%{socket: nil} = state) do
    :ets.delete(@streaming, :stream)

    state
  end

  defp noted(state) do
    :ets.insert(@streaming, {:stream, %{socket: state.socket, kind: state.kind}})

    state
  end

  # **A field that a sender did not send is one that does not change.** A telephone
  # sends the words and the picture in separate messages, so a map that named every
  # field would wipe the picture each time the title moved.
  defp told(playing) do
    %{}
    |> put_told(:title, NowPlaying.line(playing))
    |> put_told(:artwork_path, held(playing))
  end

  defp put_told(fields, _name, nil), do: fields
  defp put_told(fields, name, value), do: Map.put(fields, name, value)

  # **The picture is kept here and not sent on.** `PiFi.Artwork` holds a picture under
  # the hash of its bytes, so a telephone that sends the same sleeve for every track of
  # a record costs one copy and one thumbnail. The player and the screens read the
  # address, and none of them carries 66 KB of JPEG in a message.
  #
  # It happens in this process, which is a wait of a moment while libvips writes the
  # thumbnail. Nothing asks this process anything on the path of the audio —
  # `stream/0` reads a table — so the wait costs the music nothing.
  defp held(%{artwork: nil}), do: nil

  defp held(%{artwork: bytes}) do
    case PiFi.Artwork.put(bytes) do
      {:ok, name} ->
        "/artwork/#{name}"

      {:error, reason} ->
        Logger.warning("The artwork of an AirPlay track was not kept: #{inspect(reason)}")

        nil
    end
  end

  defp follow(:paused), do: PiFi.Player.pause(true)
  defp follow(:playing), do: PiFi.Player.pause(false)

  defp volume_enabled? do
    match?(%{enabled?: true}, Playback.volume!())
  end

  defp playing? do
    match?(%{source: AirPlay}, Playback.state!())
  end

  # One watch at a time, and the old one goes before the new one starts. A `:DOWN` of a
  # session that already ended would otherwise stop the stream that replaced it.
  defp watching(%{watch: nil} = state, nil), do: state

  defp watching(%{watch: watch} = state, nil) do
    Process.demonitor(watch, [:flush])

    %{state | watch: nil}
  end

  defp watching(state, socket) do
    state = watching(state, nil)

    %{state | watch: Process.monitor(socket)}
  end
end
