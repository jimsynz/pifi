defmodule MyHiFi.Device.Storage.Report do
  @moduledoc """
  Reads the free space of the writable partition.

  It asks `:disksup` from `os_mon`, and `:disksup.get_disk_info/0` gives the
  available space in kibibytes. `:disksup.get_disk_info/1` gives zeros for a mount
  point on this board, so this module reads the whole list and finds the mount
  point itself.

  The path comes from the repository configuration, so a host reports the partition
  that holds the development database and needs no target.
  """

  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _options, _context) do
    path = path()
    {total_bytes, free_bytes} = partition(path)

    {:ok,
     %{
       path: path,
       total_bytes: total_bytes,
       free_bytes: free_bytes,
       used_bytes: total_bytes - free_bytes,
       database_bytes: file_bytes(database())
     }}
  end

  defp path, do: Path.dirname(database())

  defp database, do: MyHiFi.Repo.config() |> Keyword.fetch!(:database)

  # More than one mount point can hold the path, and the longest one is the
  # partition that holds it. `/` holds every path.
  defp partition(path) do
    :disksup.get_disk_info()
    |> Enum.map(fn {mount, total_kib, free_kib, _percent} ->
      {to_string(mount), total_kib * 1024, free_kib * 1024}
    end)
    |> Enum.filter(fn {mount, _total, _free} -> holds?(mount, path) end)
    |> Enum.max_by(fn {mount, _total, _free} -> String.length(mount) end, fn -> nil end)
    |> case do
      {_mount, total, free} -> {total, free}
      nil -> {0, 0}
    end
  end

  defp holds?("/", _path), do: true
  defp holds?(mount, path), do: path == mount or String.starts_with?(path, mount <> "/")

  defp file_bytes(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      {:error, _reason} -> 0
    end
  end
end
