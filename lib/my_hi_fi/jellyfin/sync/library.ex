defmodule MyHiFi.Jellyfin.Sync.Library do
  @moduledoc """
  Copies the library of a Jellyfin server into the catalogue.

  `MyHiFi.AutoSync` runs this when the source is in use, the device holds a link,
  and the network answers. A person can also press a control on the settings page.

  ## It reads a page at a time

  A library holds tens of thousands of tracks, and this board holds 363.9 MB. The
  read therefore asks for one page, writes it, and lets it go. Nothing here holds
  the library, and the largest thing in memory is one page of 200 entries.

  The three kinds go in order, because an album names its artist and a track names
  its album. `MyHiFi.Jellyfin.Fill` reads the parent of each page out of the
  catalogue, so the artists must be there before the albums arrive.

  A read that fails leaves the catalogue as it stands. A person still browses what
  the device holds, and the next run reads the rest.

  ## What the read did not see, it removes

  A server that no longer holds an album must not leave that album in the list for
  ever. Each row that a read writes carries `last_seen_at`, and a read that finishes
  removes every row of this source that is older than the moment it began.

  **It removes nothing unless all three reads worked.** That one rule is what makes
  this safe, and it is the only thing that does: a read that stops half way has seen
  no track, and a remover that ran then would empty the catalogue. The `with` below
  therefore holds the removal, and a failure of any kind leaves every row where it is.
  The same is true of a device that this source is out of use on, and of one that holds
  no link: `run/3` answers before any of this.

  **An answer of nothing empties the catalogue, and that is the choice.** A fault that
  names itself removes nothing: no network gives an error, a token that stopped working
  gives 401, and a library that went gives 404, so the `with` never reaches the
  removal. An answer of 200 that holds no item is not a fault, and a person who cannot
  reach their library can play nothing of it, so the device follows the server. A
  Jellyfin that a person rebuilt answers that way while it reads its own files, and the
  next read writes the library again.

  **A mark does not hold a row back, and neither does a file on the card.** A person
  who marked an album that their server no longer holds loses that mark, because the
  catalogue follows the server. A track that goes gives up its audio as it goes,
  through the destroy of `MyHiFi.Playback.Item`, and the key of a download is the
  identifier of the row, so a later read writes a new row and reaches none of the old
  files. A read that empties the catalogue therefore costs every download of it.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query
  require Logger

  alias MyHiFi.Event
  alias MyHiFi.Jellyfin.Fill
  alias MyHiFi.Jellyfin.Server
  alias MyHiFi.Playback.Item
  alias MyHiFi.Source

  @kinds [:artists, :albums, :tracks]

  # A person who takes this source out of use expects the device to ask the server
  # for nothing. See `MyHiFi.Source.enabled?/1`.
  @impl true
  def run(_input, _options, _context) do
    if Source.enabled?(Source.Jellyfin) and Server.configured?() do
      sync()
    else
      {:ok, %{artists: 0, albums: 0, tracks: 0, removed: 0, skipped?: true}}
    end
  end

  defp sync do
    # Before the first read, so that a row which a page writes while a later page is
    # still arriving counts as one that this read saw.
    started_at = DateTime.utc_now()

    with {:ok, artists} <- read(:artists),
         {:ok, albums} <- read(:albums),
         {:ok, tracks} <- read(:tracks) do
      gone = remove_unseen(started_at)
      announce()

      Logger.info(
        "The Jellyfin library gave #{artists} artists, #{albums} albums and " <>
          "#{tracks} tracks, and #{gone} items are no longer on the server."
      )

      {:ok, %{artists: artists, albums: albums, tracks: tracks, removed: gone, skipped?: false}}
    end
  end

  # **`Ash.BulkResult` holds no count of the rows that went**, and `return_records?`
  # would hold every one of them in memory for the sake of counting them. This reads
  # the number first, in the way that `MyHiFi.Cache.purge_all/1` says to.
  #
  # A container takes what it holds with it, through the reference of
  # `MyHiFi.Playback.Item`, so the number is of the rows that this query named and not
  # always of the rows that went.
  #
  # `:stream` is not optional: the destroy of that resource reads and writes the cache
  # and gives up the audio of a track, and a strategy that wrote the rows in one
  # statement would run none of that.
  defp remove_unseen(started_at) do
    query =
      Ash.Query.filter(
        Item,
        source == ^Fill.source() and
          (is_nil(last_seen_at) or last_seen_at < ^started_at)
      )

    count = Ash.count!(query)

    if count > 0 do
      Ash.bulk_destroy!(query, :destroy, %{}, strategy: :stream, return_errors?: true)
    end

    count
  end

  defp read(kind) when kind in @kinds, do: read(kind, 0, 0)

  defp read(kind, start, written) do
    case Server.page(kind, start) do
      {:ok, %{count: 0}} ->
        {:ok, written}

      {:ok, %{entries: entries, count: count, total: total}} ->
        next = start + count

        case fill(kind, entries) + written do
          all when next >= total -> {:ok, all}
          all -> read(kind, next, all)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fill(:artists, entries), do: Fill.artists(entries)
  defp fill(:albums, entries), do: Fill.albums(entries)
  defp fill(:tracks, entries), do: Fill.tracks(entries)

  # A page that shows a branch of this source reads it again. The read takes minutes
  # on a large library, so a person is often looking at the catalogue while this
  # writes it.
  defp announce do
    Event.publish(:source, %Event.Source.Changed{source: Source.Jellyfin, ref: :library})
  end
end
