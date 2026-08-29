defmodule MyHiFi.Cache do
  @moduledoc """
  What this device holds on disk that it can fetch again.

  Any part of the firmware caches through here. A namespace says which part, and a
  key says which thing, and the caller chooses what each one means.
  `MyHiFi.Artwork` holds `:artwork` and keys by the hash of an address, and a later
  version holds `:download` and keys by the identifier of an episode.

  `MyHiFi.Cache.Entry` holds the data about one entry, and `AshStorage` writes the
  file.

  The cache grows to the free space of the partition, less a reserve, and the entry
  that a person used least recently goes first. An entry that a caller marks as one
  to keep goes never.
  """

  use Ash.Domain, otp_app: :my_hi_fi

  require Ash.Query

  alias MyHiFi.Cache.Entry

  @directory "cache"

  # The reserve protects the database and the room for a download. It is a fixed
  # number and not a share of the partition: a share of 14.2 GB gives a reserve that
  # grows for no reason, and a share of a small card gives one too small to matter.
  #
  # A test sets `:cache_limit` to a small number, so it can fill the cache and read
  # what the eviction does.
  @reserve_bytes 1024 * 1024 * 1024

  resources do
    resource MyHiFi.Cache.Entry do
      define :put, action: :put, args: [:namespace, :entry_key]
      define :put_file, action: :put_file, args: [:namespace, :entry_key]
      define :put_from_url, action: :put_from_url, args: [:namespace]
      define :fetch, action: :by_key, args: [:namespace, :entry_key]
      define :list_entries, action: :read
      define :entries_in, action: :by_namespace, args: [:namespace]
      define :touch, action: :touch
      define :keep, action: :keep
      define :release, action: :release
      define :purge, action: :purge_blob
      define :prune, action: :prune
    end

    resource MyHiFi.Cache.Attachment do
      define :attach, action: :attach
      define :attachments_of, action: :for_record, args: [:record_type, :record_id]
      define :users_of, action: :for_entry, args: [:entry_id]
      define :detach, action: :destroy
    end
  end

  @doc """
  Remove every entry that a query names, and its file with it.

  This is one bulk destroy and not a read and a purge for each row. `:stream` is not
  optional: `purge_blob` deletes the file in a `before_action` hook, and a strategy
  that writes the rows in one statement would leave every file behind.

      MyHiFi.Cache.Entry
      |> Ash.Query.filter(namespace == :artwork)
      |> MyHiFi.Cache.purge_all()

  """
  @spec purge_all(Ash.Query.t() | Ash.Resource.t()) :: :ok | {:error, term()}
  def purge_all(query) do
    # `Ash.BulkResult` counts the errors and not the rows that went, so this reports
    # that it worked and no number. A caller that needs a count reads one first.
    case Ash.bulk_destroy(query, :purge_blob, %{},
           strategy: :stream,
           return_errors?: true,
           return_records?: false
         ) do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end

  @doc """
  How many entries one record uses, and how many bytes they hold.

  **This counts at the time of the query, and it is not an aggregate of a resource.**
  `AshSqlite` answers `false` for `{:aggregate_relationship, _}`, so a `count` or a
  `sum` declared on a resource cannot compile against this data layer, whatever the
  shape of the relationship. It answers `true` for `{:query_aggregate, _}` and for
  `{:filter_relationship, _}`, which is what these two use.

      iex> MyHiFi.Cache.usage_of("show", show.id)
      %{count: 31, bytes: 37_200_000}

  """
  @spec usage_of(String.t(), Ash.UUID.t()) :: %{
          count: non_neg_integer(),
          bytes: non_neg_integer()
        }
  def usage_of(record_type, record_id) do
    query =
      Entry
      |> Ash.Query.filter(
        exists(attachments, record_type == ^record_type and record_id == ^record_id)
      )

    %{
      count: Ash.count!(query),
      bytes: Ash.sum!(query, :byte_size) || 0
    }
  end

  @doc """
  Where the cache holds its files.

  It lives on the application data partition, beside the database. That partition is
  the only writable storage of the device.
  """
  @spec directory() :: String.t()
  def directory do
    MyHiFi.Device.storage!().path |> Path.join(@directory) |> Path.expand()
  end

  @doc """
  The path of one entry under `directory/0`.

  The namespace comes first, so each part of the firmware holds its own directory and
  two callers may choose the same key.
  """
  @spec storage_key(String.t(), String.t()) :: String.t()
  def storage_key(namespace, entry_key), do: Path.join(namespace, entry_key)

  @doc """
  How many bytes the cache may hold.

  It is the free space of the partition, less a reserve of 1 GB, and it never falls
  below nothing. The old rule stopped at 64 MB, which was chosen when 247 station
  logos meant 5 MB. A podcast cover is 1.2 MB.
  """
  @spec limit() :: non_neg_integer()
  def limit do
    case Application.get_env(:my_hi_fi, :cache_limit) do
      nil -> Kernel.max(MyHiFi.Device.storage!().free_bytes - @reserve_bytes, 0)
      bytes -> bytes
    end
  end
end
