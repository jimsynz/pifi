defmodule PiFi.Cache.Entry.Changes.Write do
  @moduledoc """
  Puts the file of an entry on the disk, and records what it is.

  It builds the `key` of the extension, which is the path of the file under the root
  of the cache. `AshStorage` deletes a file by that field, so it must be the path and
  not the key of the caller.

  The fields happen in two steps, and the order is not a choice. `key`, `filename`
  and `service_name` allow no nil, so they go in while the changeset validates. The
  write and the size go in a `before_action` hook, so a row that exists names a file
  that exists and a write that fails adds no row.

  ## Two ways in

  A caller gives the `bytes` argument or the `path` argument.

  - `bytes` carries the whole file in memory. `PiFi.Artwork` uses it, because a
    picture is 46 KB and it reads the first bytes to name the type.
  - `path` names a file that already sits on this partition, and the hook moves it
    with `File.rename/2`. `PiFi.Player.Download` uses it: an episode is 50 MB, and
    a move of one partition copies no byte and cannot half finish.

  A `path` entry carries no `checksum`. `AshStorage` allows nil there, and nothing in
  this firmware reads the field, because each reader opens the file by its path. An
  md5 of 50 MB costs about a second of the CPU of this board and it answers no
  question that a caller asks.
  """

  use Ash.Resource.Change

  # Sobelow reads `@sobelow_skip` from the source. This registration stops the
  # compiler warning that no Elixir code reads the attribute.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  alias AshStorage.Service.Context
  alias AshStorage.Service.Disk
  alias PiFi.Cache

  @impl true
  def change(changeset, _options, _context) do
    namespace = Ash.Changeset.get_attribute(changeset, :namespace)
    entry_key = Ash.Changeset.get_attribute(changeset, :entry_key)

    changeset
    |> describe(namespace, entry_key)
    |> Ash.Changeset.before_action(&upload/1)
  end

  defp describe(changeset, namespace, entry_key)
       when is_binary(namespace) and is_binary(entry_key) do
    changeset
    |> Ash.Changeset.force_change_attribute(:key, Cache.storage_key(namespace, entry_key))
    # `AshStorage.BlobResource.Changes.PurgeFile` calls `blob.service_name.delete/2`,
    # so this field names the module and not a short name for it.
    |> Ash.Changeset.force_change_attribute(:service_name, Disk)
    # The attribute holds a map, and `AshStorage.Service.Disk` reads a keyword list
    # from the context. The two shapes are not the same, so each one gets its own.
    |> Ash.Changeset.force_change_attribute(:service_opts, %{root: Cache.directory()})
    |> filename(entry_key)
  end

  # A namespace or a key that is absent fails the validation of the attribute, and
  # this leaves the changeset for that to report.
  defp describe(changeset, _namespace, _entry_key), do: changeset

  # `AshStorage` asks for a filename, and a cache holds no name of its own. The key
  # of the caller serves, because no person reads it.
  defp filename(changeset, entry_key) do
    case Ash.Changeset.get_attribute(changeset, :filename) do
      nil -> Ash.Changeset.force_change_attribute(changeset, :filename, entry_key)
      _name -> changeset
    end
  end

  defp upload(changeset) do
    case Ash.Changeset.get_argument(changeset, :path) do
      nil -> write_bytes(changeset, Ash.Changeset.get_argument(changeset, :bytes))
      path -> move_file(changeset, path)
    end
  end

  defp write_bytes(changeset, bytes) do
    key = Ash.Changeset.get_attribute(changeset, :key)

    case Disk.upload(key, bytes, %Context{service_opts: [root: Cache.directory()]}) do
      :ok ->
        changeset
        |> Ash.Changeset.force_change_attribute(:byte_size, byte_size(bytes))
        |> Ash.Changeset.force_change_attribute(:checksum, checksum(bytes))
        |> Ash.Changeset.force_change_attribute(:last_accessed_at, DateTime.utc_now())

      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :bytes,
          message: "could not be written: #{inspect(reason)}"
        )
    end
  end

  # `AshStorage.Service.Disk` holds no move, so this does the two steps that its
  # `upload/3` does for bytes: it makes the directory, and it puts the file there.
  #
  # The destination is `Cache.directory/0` and the `key`, and the `key` is the
  # namespace and the entry key. `PiFi.Cache.Entry` constrains both of those, so
  # neither can hold a separator or name a parent directory.
  @sobelow_skip ["Traversal.FileModule"]
  defp move_file(changeset, path) do
    destination = Path.join(Cache.directory(), Ash.Changeset.get_attribute(changeset, :key))

    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         :ok <- destination |> Path.dirname() |> File.mkdir_p(),
         :ok <- File.rename(path, destination) do
      changeset
      |> Ash.Changeset.force_change_attribute(:byte_size, size)
      |> Ash.Changeset.force_change_attribute(:last_accessed_at, DateTime.utc_now())
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :path,
          message: "could not be moved: #{inspect(reason)}"
        )
    end
  end

  defp checksum(bytes), do: :crypto.hash(:md5, bytes) |> Base.encode64()
end
