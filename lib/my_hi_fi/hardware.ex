defmodule MyHiFi.Hardware do
  @moduledoc """
  The hardware that a person added to the board, and the boot configuration for it.

  A DAC on the I2S pins answers to nothing until the bootloader loads an overlay for
  it, so no amount of work at run time finds one. A person therefore names what they
  added, and this writes the lines that the bootloader needs. See
  `MyHiFi.Hardware.ConfigTxt` for the block, and `profiles/0` for the list.

  ## Why the choice lives in the settings

  **`fwup` formats the boot partition for each upgrade.** `task upgrade.a` of the
  Nerves system calls `fat_mkfs` before it writes, and `config.txt` is a resource that
  it writes again from the image. Nothing on that partition lasts.

  The choice therefore lives in the settings, on the data partition that no upgrade
  touches. `reconcile/0` runs at each boot: it reads the choice, it reads the file, and
  it writes the file again when the two differ. An upgrade leaves a `config.txt` with no
  block, so the boot after it writes the block and restarts one time. A rollback and a
  plain flash both repair themselves in the same way.

  ## A restart that repeats cannot begin

  `MyHiFi.Hardware.ConfigTxt.carries?/2` compares the text of the file, and never the
  hardware that answers. A profile that names an overlay which the boot partition does
  not hold therefore writes one time, restarts one time, and then agrees with itself.

  ## Which partition holds `config.txt`

  The card holds three FAT partitions. `erlinit.config` mounts the first at `/boot`, and
  that one holds `autoboot.txt`, `bootcode.bin`, and a `config.txt` of no bytes. The two
  others hold a firmware each, and the real `config.txt` is in one of them.
  `autoboot.txt` names the one that the bootloader reads, so `boot_device/0` reads that.

  ## What this needs of the Nerves system

  The bootloader reads an overlay from the boot partition, and `fwup.conf.eex` writes
  only the overlays that it names. A profile whose overlay is absent from that list
  loads nothing. Each overlay of `profiles/0` must be in it.
  """

  alias MyHiFi.Settings

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
  before a restart. See `MyHiFi.Radio.FirstSync` for the same shape.
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

  It gives `{:error, reason}` and restarts nothing when the write fails, so a person
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

  `MyHiFi.Application` calls this at each boot. It restarts the device when it writes,
  and it does nothing at all when the file already agrees. A host holds no boot
  partition and needs none, so it gives `:not_needed`.
  """
  @spec reconcile() :: :ok | :not_needed | {:error, term()}
  def reconcile, do: do_reconcile()

  @doc """
  The name of the setting that holds the choice.
  """
  @spec setting() :: String.t()
  def setting, do: @setting

  # `config.txt` belongs to the bootloader, and the bootloader runs before Linux, so a
  # host holds no such file and needs none.
  if Mix.target() == :host do
    defp do_choose(profile) do
      with {:ok, _setting} <- Settings.put(@setting, profile.id), do: :ok
    end

    defp do_reconcile, do: :not_needed
  else
    require Logger

    alias MyHiFi.Hardware.ConfigTxt

    # The card holds three FAT partitions. `erlinit.config` mounts the first at `/boot`,
    # and that one holds `autoboot.txt`, `bootcode.bin`, and a `config.txt` of no bytes.
    # The two others hold a firmware each, and the real `config.txt` is in one of them.
    #
    # `autoboot.txt` names the one that the bootloader reads, and it is the answer that
    # the bootloader itself uses. An upgrade writes the partition that is not in use and
    # then names it here, so this is always the one to write.
    #
    #     [all]
    #     tryboot_a_b=1
    #     boot_partition=2
    #     [tryboot]
    #     boot_partition=3
    #
    # A device of this firmware holds no `nerves_fw_active`, so that key answers nothing.
    @autoboot_path "/boot/autoboot.txt"
    @mount_path "/tmp/myhifi-boot"
    @config_path "/tmp/myhifi-boot/config.txt"

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
           :ok <- write(profile) do
        Logger.info("The boot configuration did not hold the #{profile.id} profile.")

        restart()
      else
        true -> :not_needed
        {:error, reason} -> {:error, reason}
      end
    end

    @doc """
    The block device that holds the `config.txt` of this boot, or `nil`.

    A device that names none gives nothing, and every write then answers
    `{:error, :no_boot_partition}`.
    """
    @spec boot_device() :: String.t() | nil
    def boot_device do
      case File.read(@autoboot_path) do
        {:ok, contents} -> named_in(contents)
        {:error, _reason} -> nil
      end
    end

    # `[all]` comes before `[tryboot]`, so the first of the two is the ordinary boot and
    # not the one that a try of a new firmware uses. The number is the partition of the
    # MBR, counting from 1, which is the number that Linux gives it as well.
    defp named_in(contents) do
      case Regex.run(~r/^\s*boot_partition\s*=\s*(\d+)/m, contents) do
        [_whole, number] -> "/dev/mmcblk0p" <> number
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
