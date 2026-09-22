defmodule PiFi.Spotify do
  @moduledoc """
  Lets a person cast Spotify to this device.

  It is a Spotify Connect target: the Spotify application on a telephone or a laptop
  lists this device beside the speakers of the house, and the audio goes straight from
  Spotify to here rather than through the telephone.

  `librespot` is what speaks the protocol, and it comes from NBPR. See
  `NBPR.Librespot`.

  ## Read this before you turn it on

  **A Spotify Premium account is required**, and the librespot project says of itself:
  *"Using this code to connect to Spotify's API is probably forbidden by them. Use at
  your own risk."* That is not a thing this firmware can decide for the person holding
  the device, so the setting says it and the person chooses.

  ## A person turns this on, and a device that no person asked leaves it off

  **It listens.** librespot advertises itself with zeroconf so that a telephone finds
  it with no account on the device, and that is a port. The rule is the one that
  `PiFi.Plex.Companion` and `PiFi.HomeAssistant` both follow: the setting decides, a
  device that no person changed opens nothing, and the supervisor starts with no child.

  ## It is not a `PiFi.Source`, and it never will be

  A source finds audio and gives a stream that `PiFi.Player` pulls. Spotify pushes:
  the telephone decides what plays and when, and nothing here resolves a track, seeks
  in one, or knows how long it is. So this holds no catalogue, writes no row, and
  appears nowhere in the browse tree.

  ## The sound card holds one program at a time

  **This is the sharp edge, and it is worth knowing before a person meets it.**
  `PiFi.Output.APlayPort` opens the card when a track plays and closes it on a stop, a
  pause or standby. librespot opens the same card when a Spotify session starts. They
  cannot both have it.

  In practice that means:

  - PiFi idle, a person casts to it — it plays. This is the common case.
  - PiFi playing, a person casts to it — librespot cannot open the card and says so in
    the log. Stopping the music here lets the cast through.

  **Nothing hands the card over by itself yet.** librespot says what it is doing
  through `--onevent`, which runs a program, and the rootfs of this device holds a
  shell and no way for a shell to reach the BEAM: busybox here has no `wget` and no
  `nc`. A handover therefore needs a mechanism that does not exist yet, and guessing
  at one is worse than saying this plainly.

  ## What librespot is given, and why it has to restart to change it

  The name, the sound card and the cache are arguments, read once when the daemon
  starts. Two of them move while a device runs: a person renames the device, or
  changes the DAC. `PiFi.Spotify.Monitor` watches the `:device` topic for both and
  starts the daemon again, because a Spotify device that kept the old name after a
  rename, or played to a card that is no longer there, is worse than a short silence.

  ## What it says, and where

  **librespot writes to stdout and stderr, and a daemon whose output goes nowhere
  cannot be debugged on a device that a person cannot reach.** `NBPR.BrPackage`
  generates a `start_link/1` that gives MuonTrap no options, so nothing captured a word
  of it: a board that connected to Spotify and played nothing had no log to read. This
  starts `MuonTrap.Daemon` itself with `binary_path/0` and `argv/1`, which NBPR
  publishes, and asks for the output at `:info` behind a `librespot: ` prefix.

  ## Volume

  librespot keeps a volume of its own, and the slider in the Spotify application
  moves it. `PiFi.Output.Volume` attenuates inside the Membrane pipeline and touches
  nothing here, so the two do not fight: a person casting uses the control in Spotify,
  and a person playing from this device uses the control here.
  """

  use Supervisor

  require Logger

  alias NBPR.Librespot.Librespot
  alias PiFi.Device.Identity
  alias PiFi.Output.Alsa
  alias PiFi.Settings

  @enabled_key "spotify.enabled"

  # librespot writes the credentials here, so a person signs in once. It goes on the
  # writable partition, which mounts at `/root` on a target. See `PiFi.Device.Storage`.
  @cache "/root/spotify"

  @doc """
  The settings key that says whether a person turned this on.

      iex> PiFi.Spotify.enabled_key()
      "spotify.enabled"
  """
  @spec enabled_key() :: String.t()
  def enabled_key, do: @enabled_key

  @doc """
  Whether a person turned this on.

  **A device that no person changed leaves it off**, because this opens a port and
  because of what the module documentation says about the licence.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Settings.fetch(@enabled_key) do
      {:ok, %{value: "true"}} -> true
      _other -> false
    end
  end

  @doc """
  Turn it on, or off.

  It starts the daemon, or it stops it, so a person hears the change without a
  restart.
  """
  @spec enable(boolean()) :: :ok
  def enable(enabled?) do
    Settings.put!(@enabled_key, to_string(enabled?))

    if enabled?, do: start_daemon(), else: stop_daemon()

    :ok
  end

  @doc "Whether the daemon is running now."
  @spec running?() :: boolean()
  def running? do
    Supervisor.which_children(__MODULE__)
    |> Enum.any?(fn {id, pid, _type, _modules} -> id == :librespot and is_pid(pid) end)
  end

  @doc """
  Start the daemon when a person asked for it.

  `PiFi.Application` calls this after the tree, in the way that it calls
  `PiFi.Plex.Companion.start_enabled/0`. **A port that another program holds must not
  stop the boot**, and a child of the tree that cannot start would do that.
  """
  @spec start_enabled() :: :ok
  def start_enabled do
    if enabled?(), do: start_daemon()

    :ok
  end

  @doc """
  Start the daemon again with what this device says now.

  `PiFi.Spotify.Monitor` calls this when the name of the device or the sound card
  changes, because librespot reads both once and never again.
  """
  @spec restart() :: :ok
  def restart do
    if running?() do
      stop_daemon()
      start_daemon()
    end

    :ok
  end

  @doc false
  @impl Supervisor
  def init(_options) do
    Supervisor.init([{PiFi.Spotify.Monitor, []}], strategy: :one_for_one)
  end

  @doc false
  def start_link(options), do: Supervisor.start_link(__MODULE__, options, name: __MODULE__)

  defp start_daemon do
    case daemon() do
      {:ok, child} -> start_child(child)
      {:error, :no_output_device} -> Logger.info("Spotify waits for a sound card.")
    end

    :ok
  end

  defp start_child(child) do
    case Supervisor.start_child(__MODULE__, child) do
      {:ok, _pid} ->
        Logger.info("Spotify can reach this device.")

      {:error, :already_present} ->
        Supervisor.restart_child(__MODULE__, :librespot)

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning("Spotify did not start: #{inspect(reason)}")
    end

    :ok
  end

  defp stop_daemon do
    Supervisor.terminate_child(__MODULE__, :librespot)
    Supervisor.delete_child(__MODULE__, :librespot)

    :ok
  end

  # **The card that the player uses is the card that Spotify uses.** A person who chose
  # a DAC chose it for everything that this device plays.
  #
  # **It asks `PiFi.Output.Alsa` and not `PiFi.Output.module/0`.** librespot opens ALSA
  # itself and knows nothing about Membrane, so what it needs is an ALSA name and not a
  # sink: the behaviour promises a sink and says nothing about what is inside one, and
  # an output that is not ALSA at all has no name to give. See
  # `PiFi.Output.Alsa.pcm_name/1`.
  # **It starts MuonTrap itself rather than calling `NBPR.Librespot.Librespot.start_link/1`.**
  # That generated function passes `[]` for the MuonTrap options, so nothing captures
  # what librespot says: a device that would not play had no log of the daemon at all,
  # and neither a person nor this project could see why. `binary_path/0` and `argv/1`
  # are what NBPR publishes for exactly this, so this is the package's own API and not
  # a way around it.
  defp daemon do
    with {:ok, device} <- alsa_device() do
      {:ok, %{id: :librespot, start: {__MODULE__, :start_librespot, [device]}}}
    end
  end

  @doc false
  # **The child spec names this and not the NBPR module**, so nothing reads the package
  # until the supervisor starts the child. The package is a target dependency, so on a
  # host it is absent, and a spec that resolved it as it was built would raise where the
  # old one let `start_child/1` log that the daemon did not start.
  @spec start_librespot(String.t()) :: GenServer.on_start()
  def start_librespot(device) do
    MuonTrap.Daemon.start_link(
      Librespot.binary_path(),
      Librespot.argv(
        name: Identity.name(),
        device: device,
        cache: @cache,
        # **An SD card has a finite number of writes.** The credentials are worth
        # keeping, so a person signs in once, and the audio of every track that they
        # play is not.
        disable_audio_cache: true
      ),
      log_output: :info,
      log_prefix: "librespot: ",
      stderr_to_stdout: true
    )
  end

  defp alsa_device do
    case PiFi.Playback.output!() do
      %{in_use: id} when is_binary(id) -> {:ok, Alsa.pcm_name(id)}
      _other -> {:error, :no_output_device}
    end
  end
end
