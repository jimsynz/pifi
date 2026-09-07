defmodule MyHiFi.Device.Storage.Report do
  @moduledoc """
  Reads the free space of the writable partition.

  **`df` gives the numbers, and not `:disksup`.** `:disksup` of `os_mon` measures on a
  timer of its own and holds the answer, and its interval is 30 minutes by default. A
  read between two measurements gives the same numbers again, so a reader that waits for
  a notification and then asks would draw the state of half an hour ago.
  `:disksup.set_check_interval/1` resets that timer and measures nothing, so there is no
  way to ask `os_mon` for a fresh figure. `df` measures when it is called, which is what
  a report after a write needs. The Nerves system holds `df` in busybox.

  `df -k -P` names the file system that holds one path, so this needs no list of the
  mount points and no rule for which one is the longest.

  `full?` is the `:disk_almost_full` alarm of `os_mon`, which `:disksup` raises for a
  mount point. It is the one notification that `os_mon` gives, and it is a threshold and
  not a figure, so it stands beside the numbers and does not take their place.

  **The alarm names a mount point, and this compares it with the mount point that `df`
  gave for the database.** An earlier version read the alarm of `/` as this partition,
  whatever the path. `/` on a Nerves device is the read only squashfs of the firmware,
  which is 100% full by construction, so `:disksup` raises that alarm at every boot. A
  device on 2026-09-07 therefore told a person that the card was full while `df` said
  28.0 GB free of 30.9 GB. There is no special mount point now: an alarm counts when it
  names the same mount point, and `/` counts on a host that keeps the database there.

  The path comes from the repository configuration, so a host reports the partition
  that holds the development database and needs no target.
  """

  use Ash.Resource.Actions.Implementation

  require Logger

  @impl true
  def run(_input, _options, _context) do
    path = path()
    {total_bytes, free_bytes, mount} = partition(path)

    {:ok,
     %{
       path: path,
       total_bytes: total_bytes,
       free_bytes: free_bytes,
       used_bytes: total_bytes - free_bytes,
       database_bytes: file_bytes(database()),
       full?: full?(mount)
     }}
  end

  defp path, do: Path.dirname(database())

  defp database, do: MyHiFi.Repo.config() |> Keyword.fetch!(:database)

  # `-P` asks for one line for each file system, so a long device name cannot fold the
  # line and move the numbers. `-k` gives 1024 byte blocks.
  defp partition(path) do
    case System.cmd("df", ["-k", "-P", path], stderr_to_stdout: true) do
      {output, 0} -> blocks(output)
      {output, status} -> report_failure(path, output, status)
    end
  rescue
    error in ErlangError ->
      Logger.warning("Could not run df: #{inspect(error)}")
      {0, 0, nil}
  end

  # The first line names the columns, and the second holds the file system that holds
  # the path. The fourth field is the available space, and the second is the size.
  #
  # **The last field is the mount point**, which `full?/1` compares with the alarm of
  # `os_mon`. `-P` puts the whole record on one line, so the last field is that mount
  # point. A mount point that holds a space would break this, and this device holds
  # `/`, `/root` and `/tmp`.
  defp blocks(output) do
    with [_header, line | _rest] <- String.split(output, "\n", trim: true),
         fields = String.split(line),
         [_name, total, _used, free | _rest] <- fields,
         {total_kib, ""} <- Integer.parse(total),
         {free_kib, ""} <- Integer.parse(free) do
      {total_kib * 1024, free_kib * 1024, List.last(fields)}
    else
      _other ->
        Logger.warning("Could not read the answer of df: #{inspect(output)}")
        {0, 0, nil}
    end
  end

  defp report_failure(path, output, status) do
    Logger.warning("df #{path} stopped with #{status}: #{inspect(output)}")

    {0, 0, nil}
  end

  # A read of `df` that failed names no mount point, and an alarm of another partition
  # then says nothing about this one.
  defp full?(nil), do: false

  defp full?(mount) do
    Enum.any?(:alarm_handler.get_alarms(), fn
      {{:disk_almost_full, alarm_mount}, _description} -> to_string(alarm_mount) == mount
      _other -> false
    end)
  end

  defp file_bytes(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      {:error, _reason} -> 0
    end
  end
end
