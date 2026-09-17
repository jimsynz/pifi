defmodule PiFi.Hardware do
  @moduledoc """
  The hardware that a person added to the board, and the boot configuration for it.

  A DAC on the I2S pins answers to nothing until the bootloader loads an overlay for
  it, so no amount of work at run time finds one. A person therefore names what they
  added, and this writes the lines that the bootloader needs. See
  `PiFi.Hardware.ConfigTxt` for the block, and `profiles/0` for the list.

  ## Why the choice lives in the settings

  **`fwup` formats the boot partition for each upgrade.** `task upgrade.a` of the
  Nerves system calls `fat_mkfs` before it writes, and `config.txt` is a resource that
  it writes again from the image. Nothing on that partition lasts.

  The choice therefore lives in the settings, on the data partition that no upgrade
  touches. `reconcile/0` runs at each boot: it reads the choice, it reads the file, and
  it writes the file again when the two differ. An upgrade leaves a `config.txt` with no
  block, so the boot after it writes the block and restarts one time. A rollback and a
  plain flash both repair themselves in the same way.

  ## A restart at boot waits for the firmware to be valid

  `Nerves.Runtime.StartupGuard` marks a new firmware as valid after every OTP application
  starts, and the bootloader gives the slot back to the firmware before it until that
  happens. `reconcile/0` runs inside that window, as a task of the supervision tree.

  **A restart there lost the upgrade.** A device on 2026-09-01 took a new firmware into
  slot A, booted it, wrote the block, restarted at once, and came back on slot B with the
  firmware that came before. `reconcile/0` of that older firmware then wrote the block for
  slot B. The profile worked and the upgrade did not, and every upgrade that also changes
  `config.txt` did the same.

  `reconcile/0` therefore waits for `Nerves.Runtime.firmware_valid?/0` before it restarts.
  It decides nothing itself. A firmware that never validates never restarts here, and the
  `:heart` callback of the guard rolls it back, which is the answer that the guard is
  there to give.

  **`choose/1` does not wait.** A person presses that on a page, long after the guard
  settled the question, and a press must answer at once.

  ## A restart that repeats cannot begin

  `PiFi.Hardware.ConfigTxt.carries?/2` compares the text of the file, and never the
  hardware that answers. A profile that names an overlay which the boot partition does
  not hold therefore writes one time, restarts one time, and then agrees with itself.

  ## Which partition carries `config.txt`

  The card has three FAT partitions. `erlinit.config` mounts the first at `/boot`, and
  that one carries `autoboot.txt`, `bootcode.bin`, and a `config.txt` of no bytes. The two
  others hold a firmware each, and the real `config.txt` is in one of them.

  **The root partition that runs says which of the two, and `autoboot.txt` does not.**
  See `boot_device/0` for the measurement that a device gave, and for what a wrong answer
  there does to this module.

  ## What this needs of the Nerves system

  The bootloader reads an overlay from the boot partition, and `fwup.conf.eex` writes
  only the overlays that it names. A profile whose overlay is absent from that list
  loads nothing. Each overlay of `profiles/0` must be in it.
  """

  alias PiFi.Settings

  @setting "hardware_profile"

  # A profile is here and not in the database, so an upgrade corrects one and no person
  # writes a line that stops a board from starting.
  @profiles [
    %{
      id: "none",
      title: "Nothing added",
      description: "A USB DAC, or the audio of the board. This needs no overlay.",
      lines: []
    },
    %{
      id: "hifiberry-dac",
      title: "HiFiBerry DAC, and Pirate Audio",
      description:
        "A DAC on the I2S pins, such as the Pimoroni Pirate Audio boards. " <>
          "BCM 25 turns it on.",
      lines: ["dtoverlay=hifiberry-dac", "gpio=25=op,dh"]
    }
  ]

  @doc """
  Run `reconcile/0` once, as a task of the supervision tree.

  It runs after the web interface starts, so a person reaches the device in the moment
  before a restart.
  """
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_argument) do
    %{id: __MODULE__, start: {Task, :start_link, [&reconcile/0]}, restart: :temporary}
  end

  @doc "Each hardware profile that this firmware knows, in the order that a person reads."
  @spec profiles() :: [map()]
  def profiles, do: @profiles

  @doc "The profile that a person chose, or the first of `profiles/0`."
  @spec chosen() :: map()
  def chosen do
    with {:ok, %{value: id}} <- Settings.fetch(@setting),
         profile when not is_nil(profile) <- Enum.find(@profiles, &(&1.id == id)) do
      profile
    else
      _other -> hd(@profiles)
    end
  end

  @doc """
  Choose a profile, write the boot configuration, and restart.

  It returns `{:error, reason}` and restarts nothing when the write fails, so a person
  reads what went wrong on the page that they pressed.
  """
  @spec choose(String.t()) :: :ok | {:error, term()}
  def choose(id) do
    case Enum.find(@profiles, &(&1.id == id)) do
      nil -> {:error, :no_such_profile}
      profile -> do_choose(profile)
    end
  end

  @doc """
  Write the boot configuration again when it does not hold the choice of a person.

  `PiFi.Application` calls this at each boot. It restarts the device when it writes,
  and it does nothing at all when the file already agrees. A host has no boot
  partition and needs none, so it returns `:not_needed`.
  """
  @spec reconcile() :: :ok | :not_needed | {:error, term()}
  def reconcile, do: do_reconcile()

  @doc """
  The name of the setting of the choice.
  """
  @spec setting() :: String.t()
  def setting, do: @setting

  # `config.txt` belongs to the bootloader, and the bootloader runs before Linux, so a
  # host has no such file and needs none.
  if Mix.target() == :host do
    defp do_choose(profile) do
      with {:ok, _setting} <- Settings.put(@setting, profile.id), do: :ok
    end

    defp do_reconcile, do: :not_needed
  else
    require Logger

    alias PiFi.Hardware.ConfigTxt

    # The card has three FAT partitions. `erlinit.config` mounts the first at `/boot`,
    # and that one carries `autoboot.txt`, `bootcode.bin`, and a `config.txt` of no bytes.
    # The two others carry a firmware each, and each one carries the `config.txt` and the
    # `cmdline.txt` of its own slot.
    @boot_devices ["/dev/mmcblk0p2", "/dev/mmcblk0p3"]
    @cmdline_path "/proc/cmdline"
    @mount_path "/tmp/pifi-boot"
    @config_path "/tmp/pifi-boot/config.txt"
    @slot_cmdline_path "/tmp/pifi-boot/cmdline.txt"

    defp do_choose(profile) do
      with {:ok, _setting} <- Settings.put(@setting, profile.id),
           :ok <- write(profile) do
        restart()
      end
    end

    defp do_reconcile do
      profile = chosen()

      with {:ok, contents} <- read(),
           false <- ConfigTxt.carries?(contents, profile.lines),
           :ok <- write(profile),
           :ok <- await_validation() do
        Logger.info("The boot configuration did not hold the #{profile.id} profile.")

        restart()
      else
        true -> :not_needed
        {:error, reason} -> {:error, reason}
      end
    end

    # The guard tries every 10 seconds. It waits for the applications and then for the
    # status, and it gives each of the two 10 tries, so 200 seconds is its own limit.
    # This waits longer than that before it stops.
    @validation_poll_ms 1_000
    @validation_wait_ms 240_000

    # A restart at boot must never discard the firmware that runs. See the moduledoc.
    #
    # `Nerves.Runtime.firmware_valid?/0` gives `true` for a device that uses no
    # validation, so such a device waits for nothing.
    defp await_validation(remaining \\ @validation_wait_ms)

    defp await_validation(remaining) when remaining <= 0 do
      Logger.error(
        "This firmware is not validated, so the device does not restart. A restart now " <>
          "would give the slot back to the firmware before it. The boot configuration " <>
          "has the profile, and the next restart uses it."
      )

      {:error, :not_validated}
    end

    defp await_validation(remaining) do
      if Nerves.Runtime.firmware_valid?() do
        :ok
      else
        Process.sleep(@validation_poll_ms)

        await_validation(remaining - @validation_poll_ms)
      end
    end

    @doc """
    The block device of the `config.txt` of this boot, or `nil`.

    **The root partition that runs is the answer, and `autoboot.txt` is not.** The
    bootloader passed the root partition on the kernel command line, so `/proc/cmdline`
    names what it chose and nothing has to presume it. Each boot partition carries the
    `cmdline.txt` of its own slot, and that file names one root partition. The boot
    partition whose `cmdline.txt` names the root that runs is the one that the bootloader
    read. `fwup-ops.conf` of the Nerves system reads the root partition for the same
    reason, with `require-path-at-offset`.

    An earlier version read `[all] boot_partition` from `autoboot.txt` instead. A device
    on 2026-09-01 held `boot_partition=2` there while it ran `/dev/mmcblk0p6`, which is
    the root partition of slot B. This module wrote the block into the `config.txt` of
    slot A, `reconcile/0` read that same file at each boot and agreed with itself, the
    bootloader never read a line of it, and the device found no sound card. Both slots
    also held `nerves_fw_validated` as `"1"` and neither held `nerves_fw_active`, so the
    U-Boot environment could not name the slot either.

    A layout that this firmware does not know gives `nil`, because no `cmdline.txt` names
    the root partition that runs. Every write then answers `{:error, :no_boot_partition}`,
    and a partition that the bootloader does not read is never written.
    """
    @spec boot_device() :: String.t() | nil
    def boot_device do
      case running_root() do
        nil -> nil
        root -> Enum.find(@boot_devices, &names_root?(&1, root))
      end
    end

    defp running_root do
      case File.read(@cmdline_path) do
        {:ok, contents} -> root_in(contents)
        {:error, _reason} -> nil
      end
    end

    # The boot partition is not mounted, so this mounts each one in turn and takes it
    # away again. A partition that does not mount gives no answer and is not the one.
    defp names_root?(device, root) do
      case mount(device) do
        :ok ->
          answer = File.read(@slot_cmdline_path)
          unmount()

          slot_root(answer) == root

        {:error, _reason} ->
          false
      end
    end

    defp slot_root({:ok, contents}), do: root_in(contents)
    defp slot_root({:error, _reason}), do: nil

    # A `cmdline.txt` carries comment lines above the one line that the kernel takes, and
    # no comment of it names `root=`. `rootwait` sits beside the name and carries no `=`,
    # so it cannot match.
    defp root_in(contents) do
      case Regex.run(~r/\broot=(\S+)/, contents) do
        [_whole, root] -> root
        nil -> nil
      end
    end

    defp read, do: with_boot(fn -> File.read(@config_path) end)

    defp write(profile) do
      with_boot(fn ->
        with {:ok, contents} <- File.read(@config_path) do
          File.write(@config_path, ConfigTxt.put(contents, profile.lines))
        end
      end)
    end

    # The boot partition is not mounted anywhere that this can write, so each read and
    # each write mounts it and takes it away again. A mount that stays would be a
    # partition that a power cut can leave half written.
    defp with_boot(fun) do
      case boot_device() do
        nil ->
          {:error, :no_boot_partition}

        device ->
          with :ok <- mount(device) do
            answer = fun.()
            unmount()

            report(answer)
          end
      end
    end

    defp mount(device) do
      File.mkdir_p(@mount_path)

      case System.cmd("mount", ["-t", "vfat", device, @mount_path], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, code} -> {:error, {:mount, code, String.trim(output)}}
      end
    end

    defp unmount, do: System.cmd("umount", [@mount_path], stderr_to_stdout: true)

    defp report({:error, reason} = error) do
      Logger.error("The boot configuration did not change: #{inspect(reason)}")

      error
    end

    defp report(answer), do: answer

    defp restart do
      Logger.info("The boot configuration changed. The device restarts now.")
      Nerves.Runtime.reboot()

      :ok
    end
  end
end
