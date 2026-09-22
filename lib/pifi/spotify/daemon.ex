defmodule PiFi.Spotify.Daemon do
  @moduledoc """
  Runs librespot and reads what it says.

  `MuonTrap.Daemon` would do the first half, and it takes the second: it owns the port
  and turns everything the program writes into log lines. **Standard output is the
  event channel here**, so this opens the port itself.

  It is still `muontrap` that runs, so the cgroup cleanup is unchanged — a daemon whose
  BEAM went away is still killed. `MuonTrap.muontrap_path/0` is public and
  `--capture-output` is the flag that `MuonTrap.Daemon` itself passes for
  `log_output:`, so this uses the same two pieces and assembles them differently.

  ## Standard output is events and standard error is the log

  `stderr_to_stdout` is gone, and that is the point rather than an omission. librespot
  writes its own log to standard error, `priv/spotify/librespot-event` writes blocks to
  standard output, and mixing them would mean parsing one out of the other. The log
  still reaches a person: it goes where the standard error of the BEAM goes, which on a
  device is the system log.

  ## `--emit-sink-events` is not in the package

  `NBPR.Librespot.Librespot.argv/1` builds every option this needs except that one, so
  this appends it. Adding it to NBPR is the right home for it and it cannot be
  released: an NBPR package version mirrors the version of the thing it packages, and
  librespot 0.8.0 fills every slot hex.pm takes. See `PiFi.Bluetooth` for the same
  deadlock met from the other side.

  ## It plays into the loopback

  **librespot never opens the sound card now.** It writes to one half of an ALSA
  loopback and `PiFi.Spotify.CaptureSource` reads the other, so `aplay` is the only
  program that opens the card and a cast is a stream that `PiFi.Player` carries like
  any other. The rule about stopping the music before casting is gone with it.

  ## What it does with an event

  It publishes. A daemon that reached into the player would be a second thing deciding
  what plays, and the sink events are exactly the handover that
  `PiFi.Event.Spotify.SinkChanged` exists to announce.
  """

  use GenServer

  require Logger

  alias NBPR.Librespot.Librespot
  alias PiFi.Device.Identity
  alias PiFi.Event
  alias PiFi.Spotify.Events

  # librespot writes the credentials here, so a person signs in once. It goes on the
  # writable partition, which mounts at `/root` on a target.
  @cache "/root/spotify"

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{device: String.t() | nil, port: port() | nil, held: String.t()}

    defstruct device: nil, port: nil, held: ""
  end

  @doc false
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @doc """
  The arguments that librespot is given.

  It is public so that a test can read them without starting anything, and so that a
  person reading a log can see what the daemon was told.
  """
  @spec argv(String.t(), String.t()) :: [String.t()]
  def argv(script, device) do
    Librespot.argv(
      name: Identity.name(),
      device: device,
      cache: @cache,
      # **An SD card has a finite number of writes.** The credentials are worth keeping,
      # so a person signs in once, and the audio of every track that they play is not.
      disable_audio_cache: true,
      onevent: "/bin/sh " <> script
    ) ++ ["--emit-sink-events"]
  end

  @doc """
  The script that librespot runs for each event.

  It ships in `priv` and it is read from there: nothing copies it to the rootfs, which
  is read only in any case.
  """
  @spec event_script() :: String.t()
  def event_script do
    :pifi
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("spotify/librespot-event")
  end

  # **The port opens here and not in a continue.** A daemon that started and then
  # crashed would be restarted by its supervisor, again and immediately, until the
  # supervisor gave up and took everything above it with it. A host has no librespot at
  # all, so this is the ordinary case on a laptop rather than an unlikely one: returning
  # `{:stop, reason}` lets `start_child/1` log that the daemon did not start, which is
  # what the supervisor above expects and what the old `MuonTrap.Daemon` did.
  @doc false
  @impl GenServer
  def init(options) do
    Process.flag(:trap_exit, true)

    device = Keyword.fetch!(options, :device)

    case open(device) do
      {:ok, port} -> {:ok, %State{device: device, port: port}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @doc false
  @impl GenServer
  def handle_info({port, {:data, bytes}}, %State{port: port} = state) do
    {events, held} = Events.take(state.held <> bytes)

    Enum.each(events, &announce/1)

    {:noreply, %State{state | held: held}}
  end

  def handle_info({port, {:exit_status, status}}, %State{port: port} = state) do
    Logger.warning("librespot stopped with status #{status}.")

    {:stop, :error_exit_status, %State{state | port: nil}}
  end

  def handle_info(message, state) do
    Logger.debug("Spotify ignoring #{inspect(message)}")

    {:noreply, state}
  end

  # **A sink event is the only thing that says a cast began or ended.** The capture side
  # of the loopback hands over silence at full rate whether anything plays or not, so
  # nothing downstream may start itself on data. See `PiFi.Spotify.Loopback`.
  defp announce(event) do
    case Events.sink(event) do
      nil -> :ok
      state -> Event.publish(:player, %Event.Spotify.SinkChanged{state: state})
    end

    case Events.track(event) do
      nil -> :ok
      track -> Event.publish(:player, %Event.Spotify.TrackChanged{track: track})
    end

    :ok
  end

  # **librespot still plays to the sound card, and the loopback is not wired up yet.**
  # The capture element exists and nothing starts it, so a cast routed into the loopback
  # would go nowhere and a person would get silence where they get music today. The
  # device moves to `PiFi.Spotify.Loopback.playback_device/0` in the change that teaches
  # `PiFi.Player` to carry a stream with no item, and not before.
  defp open(device) do
    args = argv(event_script(), device)

    port =
      Port.open({:spawn_executable, to_charlist(MuonTrap.muontrap_path())}, [
        :use_stdio,
        :exit_status,
        :binary,
        :hide,
        args: ["--capture-output", "--", Librespot.binary_path()] ++ args
      ])

    Logger.info("Spotify can reach this device.")

    {:ok, port}
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end
end
