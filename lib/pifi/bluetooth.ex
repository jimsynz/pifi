defmodule PiFi.Bluetooth do
  @moduledoc """
  Plays to a Bluetooth speaker or a pair of headphones.

  **The audio path of this firmware already ends at an ALSA device name**, and that is
  the whole reason this fits. `bluez-alsa` installs a userspace ALSA plugin, so a paired
  speaker is `bluealsa:DEV=AA:BB:CC:DD:EE:FF` where the USB DAC is
  `rate48:CARD=Audio,DEV=0`. `PiFi.Output.Alsa` lists both, and nothing in the player,
  the pipeline or the sink learns a word of Bluetooth.

  ## Three daemons, and the order is the order

  - `dbus-daemon` carries the system bus. BlueZ claims `org.bluez` on it as it starts
    and exits when there is no bus to claim it on.
  - `bluetoothd` owns the adapter and the pairings.
  - `bluealsa` turns a paired device into that ALSA name. It routes nothing until it
    is told a profile, and `a2dp-source` is the one that **sends** audio to a speaker.
    `a2dp-sink`, which takes audio from a telephone, is a separate feature.

  All three come from NBPR, because they are binaries and a Nerves system is not where
  a binary belongs. The kernel side cannot: `CONFIG_BT` and the `.hcd` blob of the radio
  are loaded long before any of the rootfs is this project's code, so they live in
  version 0.2.0 of the system.

  ## A person turns this on, and a device that no person asked leaves it off

  Three daemons, a radio that answers to anything in range, and a pairing agent are not
  what a device that nobody asked for should be running. This follows the rule that
  `PiFi.Plex.Companion` and `PiFi.Spotify` follow: the setting decides, and the
  supervisor starts with no child.

  ## The sound is SBC, and that is the cost

  A2DP requires SBC and every device has it. AAC, aptX and LDAC each need another
  library in the rootfs, and neither this firmware nor NBPR ships one, so a FLAC of a
  library reaches a speaker as SBC. **A person who wants the quality of this device uses
  the USB DAC**, and Bluetooth is for the case that the issue asked for: headphones.

  ## Where the pairing is kept

  `bluetoothd` writes the keys under `/var/lib/bluetooth`, which is read-only squashfs
  here. Version 0.2.0 of the system points that at `/root/bluetooth`, which is the
  writable partition, so a speaker pairs once and not at every boot.

  **The symlink is half of it and this side is the other half.** `/root` is its own
  partition and a fresh one is empty, so nothing the image ships can put a directory
  there. Until `keep_pairings/0` makes it the link dangles, `bluetoothd` has nowhere to
  write, and it reports that to nobody: a board paired a headset, rebooted, and knew
  nothing about it.
  """

  use Supervisor

  require Logger

  alias NBPR.Bluez5Utils.Bluetoothd
  alias NBPR.BluezAlsa.Bluealsad
  alias NBPR.Dbus.DbusDaemon
  alias PiFi.Settings

  @enabled_key "bluetooth.enabled"

  # Where the system's `/var/lib/bluetooth` symlink points. See `keep_pairings/0`.
  @state_directory "/root/bluetooth"

  # A stereo sends audio to a speaker. Taking audio from a telephone is the other half
  # of Bluetooth audio and a separate feature, and a daemon that was told both would
  # advertise this device as a speaker as well.
  @profiles ["a2dp-source"]

  # **Two files are called `system.conf` and only one of them starts a bus.**
  # `usr/share/dbus-1/system.conf` in the package's priv is the real configuration;
  # `etc/dbus-1/system.conf` beside it is D-Bus's legacy stub, and at 1.14.10 its whole
  # body is `<busconfig></busconfig>`. Handing the stub to `--config-file` starts
  # nothing and says very little about why.
  #
  # `priv/dbus/system.conf` is a copy of the real one with `<user>dbus</user>` changed
  # to `root`, because a Nerves rootfs has no `dbus` user and the bus will not start as
  # one it cannot find.
  #
  # **It is a template rather than a rootfs file, because of the policy.** BlueZ and
  # BlueALSA each ship a `.conf` that lets them own `org.bluez` and `org.bluealsa`, and
  # without it the bus refuses the name and the daemon exits a second later. NBPR
  # installs those under the package's own priv, so the path holds the version of the
  # package and cannot be written into a file that ships. `bus_config/0` resolves them
  # at start and writes the result where the daemon can read it.
  # **The template is read at compile time and not at each start.** It never changes
  # while a device runs, a read that cannot fail is one less way for the bus not to
  # start, and `@external_resource` makes a change to the file recompile this module.
  @template_path Path.join(__DIR__, "../../priv/dbus/system.conf")
  @external_resource @template_path
  @template File.read!(@template_path)

  @policy_marker "@policy_dirs@"
  @policy_packages [:nbpr_bluez5_utils, :nbpr_bluez_alsa]
  @bus_config "/root/dbus-system.conf"

  @doc """
  The settings key that says whether a person turned this on.

      iex> PiFi.Bluetooth.enabled_key()
      "bluetooth.enabled"
  """
  @spec enabled_key() :: String.t()
  def enabled_key, do: @enabled_key

  @doc "Whether a person turned Bluetooth on."
  @spec enabled?() :: boolean()
  def enabled? do
    case Settings.fetch(@enabled_key) do
      {:ok, %{value: "true"}} -> true
      _other -> false
    end
  end

  @doc """
  Turn Bluetooth on, or off.

  It starts the three daemons, or it stops them, so a person sees the change without a
  restart.
  """
  @spec enable(boolean()) :: :ok
  def enable(enabled?) do
    Settings.put!(@enabled_key, to_string(enabled?))

    if enabled?, do: start_daemons(), else: stop_daemons()

    :ok
  end

  @doc "Whether the daemons are running now."
  @spec running?() :: boolean()
  def running? do
    Supervisor.which_children(__MODULE__)
    |> Enum.any?(fn {id, pid, _type, _modules} -> id == :bluealsa and is_pid(pid) end)
  end

  @doc """
  Whether this board has a Bluetooth radio at all.

  **The same image runs on a board with one and on a board without**, so a settings page
  asks this before it offers the switch. An empty `/sys/class/bluetooth` means the
  kernel found no adapter, and no daemon will change that.
  """
  @spec adapter?() :: boolean()
  def adapter? do
    match?({:ok, [_adapter | _rest]}, File.ls("/sys/class/bluetooth"))
  end

  @doc """
  Start the daemons when a person asked for them.

  `PiFi.Application` calls this after the tree, in the way that it calls
  `PiFi.Plex.Companion.start_enabled/0`. **A daemon that will not start must not stop
  the boot**, and a child of the tree that cannot start would do that.
  """
  @spec start_enabled() :: :ok
  def start_enabled do
    if enabled?() and adapter?(), do: start_daemons()

    :ok
  end

  @doc false
  @impl Supervisor
  def init(_options), do: Supervisor.init([], strategy: :rest_for_one)

  @doc false
  def start_link(options), do: Supervisor.start_link(__MODULE__, options, name: __MODULE__)

  # **`:rest_for_one` and not `:one_for_one`.** BlueZ claims its name on the bus as it
  # starts, and `bluealsa` finds the adapter through BlueZ, so a bus that restarts
  # leaves the two above it talking to a bus that no longer holds their names. Each one
  # therefore takes the ones after it with it.
  defp start_daemons do
    keep_pairings()

    for child <- [dbus_daemon(), bluetoothd(), bluealsa(), client(), agent()],
        do: start_child(child)

    :ok
  end

  # **The system points `/var/lib/bluetooth` at `/root/bluetooth` and cannot create it.**
  # `/root` is its own partition and it starts empty, so the symlink the image ships
  # dangles until something on this side makes the directory. A board paired a headset,
  # rebooted, and knew nothing about it: `bluetoothd` had nowhere to write the keys and
  # said so to nobody. This is the same job `PiFi.Migrator` and `PiFi.DeviceSecrets` do
  # for their own files.
  defp keep_pairings do
    case File.mkdir_p(@state_directory) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Bluetooth cannot keep pairings in #{@state_directory}: #{:file.format_error(reason)}. " <>
            "A speaker will pair again at each boot."
        )
    end
  end

  defp start_child(child) do
    case Supervisor.start_child(__MODULE__, child) do
      {:ok, _pid} ->
        Logger.info("Bluetooth started #{inspect(child.id)}.")

      {:error, :already_present} ->
        Supervisor.restart_child(__MODULE__, child.id)

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning("Bluetooth did not start #{inspect(child.id)}: #{inspect(reason)}")
    end

    :ok
  end

  defp stop_daemons do
    for id <- [PiFi.Bluetooth.Agent, PiFi.Bluetooth.Bus, :bluealsa, :bluetoothd, :dbus] do
      Supervisor.terminate_child(__MODULE__, id)
      Supervisor.delete_child(__MODULE__, id)
    end

    :ok
  end

  # **The bus needs a directory that a Nerves rootfs does not have.** `/run` is a tmpfs
  # that comes up empty on every boot, and `dbus-daemon` will not make the parent of its
  # own socket: it fails with `Failed to bind socket` and the whole stack stops behind
  # it. Nothing else writes here, so this is the place that makes it.
  defp dbus_daemon do
    File.mkdir_p!("/run/dbus")
    File.write!(@bus_config, bus_config())

    %{
      id: :dbus,
      start:
        {MuonTrap.Daemon, :start_link,
         [
           DbusDaemon.binary_path(),
           DbusDaemon.argv(config_file: @bus_config, foreground: true),
           [log_output: :info, log_prefix: "dbus-daemon: ", stderr_to_stdout: true]
         ]}
    }
  end

  # The template, with one `<includedir>` for each package that ships a policy. A
  # package that a build left out is skipped rather than named, because an
  # `<includedir>` that points nowhere is a warning on every start of the bus.
  defp bus_config do
    dirs =
      @policy_packages
      |> Enum.map(&policy_dir/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join("\n  ", &"<includedir>#{&1}</includedir>")

    String.replace(@template, @policy_marker, dirs)
  end

  defp policy_dir(app) do
    case :code.priv_dir(app) do
      {:error, _reason} ->
        nil

      path ->
        dir = path |> to_string() |> Path.join("usr/share/dbus-1/system.d")

        if File.dir?(dir), do: dir
    end
  end

  # **The client comes last and it is part of the group.** `:rest_for_one` restarts what
  # follows a child that went, so a bus that restarts takes the connection with it: a
  # connection to a daemon that is no longer there is worse than no connection at all.
  defp client do
    %{id: PiFi.Bluetooth.Bus, start: {PiFi.Bluetooth.Bus, :start_link, [[]]}}
  end

  # **It comes after the bus and not before it.** The agent registers an object on that
  # connection and then tells BlueZ where to find it, so a bus that is not up yet is an
  # agent BlueZ is told about and cannot call. See `PiFi.Bluetooth.Agent`.
  defp agent do
    %{id: PiFi.Bluetooth.Agent, start: {PiFi.Bluetooth.Agent, :start_link, [[]]}}
  end

  defp bluetoothd do
    %{
      id: :bluetoothd,
      start:
        {MuonTrap.Daemon, :start_link,
         [
           Bluetoothd.binary_path(),
           Bluetoothd.argv([]),
           [log_output: :info, log_prefix: "bluetoothd: ", stderr_to_stdout: true]
         ]}
    }
  end

  # **`binary_path/0` of this one names a binary that is not there.** bluez-alsa renamed
  # the daemon `bluealsa` to `bluealsad` in v5.0.0, Buildroot 2026.05.3 builds v4.3.1,
  # and the wrapper carries the v5 name. A board reported
  # `.../nbpr_bluez_alsa-4.3.1/priv/usr/bin/bluealsad` while the package ships
  # `bluealsa` beside `bluealsa-aplay` and `bluealsa-cli`.
  #
  # The fix is merged in NBPR and cannot be released: a package version there mirrors
  # the version of the thing it packages, and 4.3.1 fills every slot hex.pm accepts.
  # So this builds the path the way the package does and takes `argv/1` from it, which
  # was always right. Delete `bluealsa_path/0` when a release carries the corrected one.
  defp bluealsa do
    %{
      id: :bluealsa,
      start:
        {MuonTrap.Daemon, :start_link,
         [
           bluealsa_path(),
           Bluealsad.argv(profiles: @profiles),
           [log_output: :info, log_prefix: "bluealsa: ", stderr_to_stdout: true]
         ]}
    }
  end

  # **An NBPR binary runs from the package's priv and not from the rootfs.** The `path:`
  # in a package declaration reads like `/usr/bin/…` and is a path inside `priv`, so
  # nothing of NBPR is on `PATH` and a literal rootfs path finds nothing at all.
  defp bluealsa_path do
    :nbpr_bluez_alsa
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("usr/bin/bluealsa")
  end
end
