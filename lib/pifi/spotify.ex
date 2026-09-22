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

  ## This is the daemon, and `PiFi.Source.Spotify` is the face of it

  Spotify pushes: the telephone decides what plays and when, and nothing here resolves
  a track, seeks in one, or knows how long it is. So this holds no catalogue, writes no
  row, and appears nowhere in the browse tree.

  **It is still a source**, because that is where a person looks for the switch. See
  `PiFi.Source.Spotify` for why, and for what a page draws in the place of a tree. That
  module owns the setting; this one owns the process.

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

  alias PiFi.Source
  alias PiFi.Spotify.Loopback

  @doc """
  Whether a person turned this on.

  It is the same setting as every other source, and `PiFi.Source.Spotify.ready?/0` is
  what leaves it off on a device that no person changed.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Source.enabled?(Source.Spotify)

  @doc "Whether the daemon is running now."
  @spec running?() :: boolean()
  def running? do
    Supervisor.which_children(__MODULE__)
    |> Enum.any?(fn {id, pid, _type, _modules} -> id == :librespot and is_pid(pid) end)
  end

  @doc """
  Start the daemon, or stop it, to match what a person asked for.

  `PiFi.Application` calls this after the tree, in the way that it calls
  `PiFi.Plex.Companion.start_enabled/0`. **A port that another program holds must not
  stop the boot**, and a child of the tree that cannot start would do that.

  `PiFi.Spotify.Monitor` calls it again whenever the setting changes, so a person hears
  the change without a restart. The control they press is the generic source switch,
  which knows nothing about daemons. See `PiFi.Event.Source.EnabledChanged`.
  """
  @spec follow_setting() :: :ok
  def follow_setting do
    if enabled?(), do: start_daemon(), else: stop_daemon()

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
      {:error, reason} -> Logger.info("Spotify waits for the ALSA loopback: #{inspect(reason)}")
    end

    :ok
  end

  defp start_child(child) do
    case Supervisor.start_child(__MODULE__, child) do
      {:ok, _pid} ->
        :ok

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
  # **It plays into the ALSA loopback and never into the sound card.** `aplay` stays the
  # one program that opens the card, and a cast becomes a stream that `PiFi.Player`
  # carries like any other. See `PiFi.Spotify.Loopback`.
  #
  # **The child spec names `PiFi.Spotify.Daemon` and not the NBPR module**, so nothing
  # reads the package until the supervisor starts the child. The package is a target
  # dependency, so on a host it is absent, and a spec that resolved it as it was built
  # would raise where this lets `start_child/1` log that the daemon did not start.
  # **The loopback is what librespot plays into**, so it is what the daemon waits for
  # rather than a sound card. The card is still needed, but `PiFi.Player` opens it
  # through `aplay` when the cast starts, in the way it does for everything else.
  defp daemon do
    with :ok <- Loopback.ensure_loaded() do
      {:ok,
       %{
         id: :librespot,
         start: {PiFi.Spotify.Daemon, :start_link, [[device: Loopback.playback_device()]]}
       }}
    end
  end
end
