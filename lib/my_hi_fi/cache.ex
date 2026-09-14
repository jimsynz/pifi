defmodule MyHiFi.Cache do
  @moduledoc """
  What this device keeps on disk that it can fetch again.

  Any part of the firmware caches through here. A namespace says which part, and a
  key says which thing, and the caller chooses what each one means.
  `MyHiFi.Artwork` uses `:artwork` and keys by the hash of an address, and a later
  version uses `:download` and keys by the identifier of an episode.

  `MyHiFi.Cache.Entry` keeps the data about one entry, and `AshStorage` writes the
  file.

  The cache grows to the free space of the partition, less a reserve, and the entry
  that a person used least recently goes first. An entry that a caller marks as one
  to keep goes never.
  """

  use Ash.Domain, otp_app: :my_hi_fi

  require Ash.Query

  alias MyHiFi.Cache.Entry
  alias MyHiFi.Cache.Touches

  @directory "cache"

  # The reserve protects the database and the room for a download. It is a fixed
  # number and not a share of the partition: a share of 14.2 GB gives a reserve that
  # grows for no reason, and a share of a small card gives one too small to matter.
  #
  # A test sets `:cache_limit` to a small number, so it can fill the cache and read
  # what the eviction does.
  @reserve_bytes 1024 * 1024 * 1024

  # **How old a used mark must be before a read writes a new one.** The eviction cannot
  # tell two entries of one hour apart, so a write inside that hour changes no answer
  # and costs a card that must run for years. See `used/1`.
  @touch_after_seconds 3600

  resources do
    resource MyHiFi.Cache.Entry do
      define :put, action: :put, args: [:namespace, :entry_key]
      define :put_file, action: :put_file, args: [:namespace, :entry_key]
      define :put_from_url, action: :put_from_url, args: [:namespace]
      define :fetch, action: :by_key, args: [:namespace, :entry_key]
      define :fetch_many, action: :by_keys, args: [:namespace, :entry_keys]
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
  Note that something used one entry.

  The eviction takes the entry that something used least recently, so each read of an
  entry says that it happened. This is the door for that, and `touch/1` is the write
  that it leads to.

  **It writes nothing for a row that already says that it was used inside the hour.**
  The eviction cannot tell two entries of one hour apart, so such a write changes no
  answer and costs a card that must run for years. A page of the web interface reads
  25 pictures, and a person who opens it again reads the same 25.

  A mark that it does keep goes to `MyHiFi.Cache.Touches`, which keeps it in memory and
  writes it with the others. A firmware that runs no buffer writes the row at once.
  """
  @spec used(Entry.t()) :: :ok
  def used(entry) do
    if stale?(entry) and Touches.record(entry.id) == :none do
      touch(entry)
    end

    :ok
  end

  @doc """
  Note that something used every entry that a query names.

  `MyHiFi.Cache.Touches` writes its buffer with this, so one flush is one statement and
  one acquisition of the write lock. Every row takes the same time, which is what a
  least recently used order needs. See that module.
  """
  @spec touch_all(Ash.Query.t() | Ash.Resource.t()) :: :ok | {:error, term()}
  def touch_all(query) do
    case Ash.bulk_update(query, :touch, %{}, return_errors?: true, return_records?: false) do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> {:error, errors}
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
  How many bytes the entries of the cache hold.

  It counts every entry, and one that a caller marked with `keep?` counts like any
  other. The eviction reads this against `limit/0`.
  """
  @spec bytes() :: non_neg_integer()
  def bytes, do: Ash.sum!(Entry, :byte_size) || 0

  @doc """
  How many bytes the cache may still take before it passes its limit.

  It is 0 for a cache that is at its limit or past it.
  `MyHiFi.Playback.FavouriteAudio` reads this before it asks for a track, because a
  read that no eviction can make room for must not start.
  """
  @spec free_bytes() :: non_neg_integer()
  def free_bytes, do: Kernel.max(limit() - bytes(), 0)

  @doc """
  Where the cache keeps its files.

  It lives on the application data partition, beside the database. That partition is
  the only writable storage of the device.
  """
  @spec directory() :: String.t()
  def directory do
    MyHiFi.Device.storage!().path |> Path.join(@directory) |> Path.expand()
  end

  @doc """
  The path of one entry under `directory/0`.

  The namespace comes first, so each part of the firmware gets its own directory and
  two callers may choose the same key.
  """
  @spec storage_key(String.t(), String.t()) :: String.t()
  def storage_key(namespace, entry_key), do: Path.join(namespace, entry_key)

  @doc """
  How many bytes the cache may hold.

  It is the space of the partition that nothing else holds, less a reserve of 1 GB,
  and it never falls below nothing. The old rule stopped at 64 MB, which was chosen
  when 247 station logos meant 5 MB. A podcast cover is 1.2 MB.

  **What the cache already holds is a part of that space, and the count must add it
  back.** The free space of the partition is what is free now, and the files of the
  cache are not free, so a rule that read that number alone shrank its own ceiling
  with every file that it wrote. The cache then stopped at half of what it may have:

      C = free - reserve, and free = total - other - C, so C = (total - other - reserve) / 2

  A board on 2026-09-14 held a card of 14,539 MB with 1,591 MB of other files. The
  rule gave 5,981 MB and the cache held 5,943 MB of it, where 11,924 MB was free for
  it. Every picture of a library of 5,169 covers was read and then removed, because
  the audio of a marked album carries `keep?` and a picture is what an eviction can
  take.
  """
  @spec limit() :: non_neg_integer()
  def limit do
    case Application.get_env(:my_hi_fi, :cache_limit) do
      nil -> Kernel.max(MyHiFi.Device.storage!().free_bytes + bytes() - @reserve_bytes, 0)
      bytes -> bytes
    end
  end

  # An entry that a caller wrote a moment ago carries the time of that write, so a read
  # of it needs no mark at all.
  #
  # A test sets `:cache_touch_after_seconds` to 0, so a read marks each time and the
  # order of an eviction is what that test is about. Nothing sets it in production, in
  # the way that nothing sets `:cache_limit`.
  defp stale?(%{last_accessed_at: nil}), do: true

  defp stale?(%{last_accessed_at: at}) do
    DateTime.diff(DateTime.utc_now(), at, :second) >= touch_after_seconds()
  end

  defp touch_after_seconds do
    Application.get_env(:my_hi_fi, :cache_touch_after_seconds, @touch_after_seconds)
  end
end
