defmodule MyHiFi.Cache.Entry.Changes.Write do
  @moduledoc """
  Writes the bytes of an entry to the disk, and holds what they are.

  It builds the `key` of the extension, which is the path of the file under the root
  of the cache. `AshStorage` deletes a file by that field, so it must be the path and
  not the key of the caller.

  The fields happen in two steps, and the order is not a choice. `key`, `filename`
  and `service_name` allow no nil, so they go in while the changeset validates. The
  upload and the size and the sum of the bytes go in a `before_action` hook, so a row
  that exists names a file that exists and a write that fails adds no row.
  """

  use Ash.Resource.Change

  alias AshStorage.Service.Context
  alias AshStorage.Service.Disk
  alias MyHiFi.Cache

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
    # so this field holds the module and not a short name for it.
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
    bytes = Ash.Changeset.get_argument(changeset, :bytes)
    key = Ash.Changeset.get_attribute(changeset, :key)
    options = [root: Cache.directory()]

    case Disk.upload(key, bytes, %Context{service_opts: options}) do
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

  defp checksum(bytes), do: :crypto.hash(:md5, bytes) |> Base.encode64()
end
