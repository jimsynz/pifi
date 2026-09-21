defmodule PiFi.Jellyfin.Sync.Library do
  @moduledoc """
  Copies the library of a Jellyfin server into the catalogue.

  `PiFi.AutoSync` runs this when the source is in use, the device has a link,
  and the network answers. A person can also press a control on the settings page.

  ## It reads a page at a time

  A library has tens of thousands of tracks, and this board has 363.9 MB. The
  read therefore asks for one page, writes it, and lets it go. Nothing here keeps
  the library, and the largest thing in memory is one page of 200 entries.

  The three kinds go in order, because an album names its artist and a track names
  its album. `PiFi.Jellyfin.Fill` reads the parent of each page out of the
  catalogue, so the artists must be there before the albums arrive.

  A read that fails leaves the catalogue as it stands. A person still browses what
  the device has read, and the next run reads the rest.

  ## A read that stops continues where it stopped

  A read of 67,508 items takes about 88 minutes, and this device stops often: it goes
  into standby, a person takes the power away, and a new firmware restarts it.
  `Oban.Lifeline` gives such a job back to the queue, and a read that began again from
  nothing would ask the server for the whole library a second time.

  `PiFi.Jellyfin.Sync.Checkpoint` therefore keeps the kind and the offset that the
  read has reached, and a read that finds one continues from it. See `start_point/0`
  for the two things that make this safe: the time of the first read carries over, and
  a point that is too old is left alone.

  ## What the read did not see, it removes

  A server that no longer has an album must not leave that album in the list for
  ever. Each row that a read writes carries `last_seen_at`, and a read that finishes
  removes every row of this source that is older than the moment it began.

  **It removes nothing unless all three reads worked.** That one rule is what makes
  this safe, and it is the only thing that does: a read that stops half way has seen
  no track, and a remover that ran then would empty the catalogue. The `with` below
  therefore stops the removal, and a failure of any kind leaves every row where it is.
  The same is true of a device that this source is out of use on, and of one that has
  no link: `run/3` answers before any of this.

  **An answer of nothing empties the catalogue, and that is the choice.** A fault that
  names itself removes nothing: no network gives an error, a token that stopped working
  gives 401, and a library that went gives 404, so the `with` never reaches the
  removal. An answer of 200 with no item is not a fault, and a person who cannot
  reach their library can play nothing of it, so the device follows the server. A
  Jellyfin that a person rebuilt answers that way while it reads its own files, and the
  next read writes the library again.

  **A mark does not hold a row back, and neither does a file on the card.** A person
  who marked an album that their server no longer has loses that mark, because the
  catalogue follows the server. A track that goes gives up its audio as it goes,
  through the destroy of `PiFi.Playback.Item`, and the key of a download is the
  identifier of the row, so a later read writes a new row and reaches none of the old
  files. A read that empties the catalogue therefore costs every download of it.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query
  require Logger

  alias PiFi.Event
  alias PiFi.Jellyfin.Fill
  alias PiFi.Jellyfin.Server
  alias PiFi.Jellyfin.Sync.Checkpoint
  alias PiFi.Jellyfin.Sync.Survey
  alias PiFi.Playback.Item
  alias PiFi.Settings
  alias PiFi.Source

  @kinds [:artists, :albums, :tracks]

  # When the last whole read finished, and how long a survey may stand in for one.
  @whole_read_key "jellyfin.library.whole_read_at"
  @whole_read_after 7 * 24 * 60 * 60

  # How old a point may be and still serve. A read takes about 88 minutes, and
  # `PiFi.AutoSync` runs the work again within the hour, so a point of any use is
  # hours old at the most. Six hours leaves room for a device that a person switched
  # off for an evening, and it refuses a point from another day.
  @forget_after 6 * 60 * 60

  # A person who takes this source out of use expects the device to ask the server
  # for nothing. See `PiFi.Source.enabled?/1`.
  @impl true
  def run(_input, _options, _context) do
    if Source.enabled?(Source.Jellyfin) and Server.configured?() do
      sync()
    else
      {:ok, %{artists: 0, albums: 0, tracks: 0, removed: 0, skipped?: true}}
    end
  end

  # **Most days a library gained nothing**, and a read of the whole of one is 88 minutes
  # and tens of thousands of writes that everything else on this device queues behind.
  # `PiFi.Jellyfin.Sync.Survey` asks three cheap questions first and says which of these
  # three is needed. See that module for what a count cannot see.
  defp sync do
    with {:ok, link} <- Server.link() do
      case survey(link) do
        :nothing -> unchanged()
        {:added, entries} -> added(entries)
        :everything -> whole(link)
      end
    end
  end

  # **A whole read happens on a clock of its own whatever the survey says.** A library
  # that gained one record and lost another counts the same, and an edit changes no
  # count at all, so a survey that was always trusted would let those drift for ever.
  defp survey(link) do
    if due_for_a_whole_read?(), do: :everything, else: Survey.take(link)
  end

  defp unchanged do
    Logger.info("The Jellyfin library is as this device last read it.")

    {:ok, empty(%{})}
  end

  # An addition is the one case that needs no removal: the survey saw the server holding
  # at least as many of every kind, so nothing went.
  defp added(entries) do
    counts = Map.new(@kinds, &{&1, fill(&1, Map.get(entries, &1, []))})

    Logger.info(
      "The Jellyfin library gained #{counts.artists} artists, #{counts.albums} albums " <>
        "and #{counts.tracks} tracks."
    )

    announce()

    {:ok, empty(counts)}
  end

  defp empty(counts) do
    Map.merge(%{artists: 0, albums: 0, tracks: 0, removed: 0, skipped?: false}, counts)
  end

  defp whole(link) do
    %{started_at: started_at, kind: kind, offset: offset} = start_point()

    with {:ok, counts} <- read_from(kind, offset, started_at, link) do
      gone = remove_unseen(started_at)
      forget_point()
      whole_read_done()
      announce()

      Logger.info(
        "The Jellyfin library gave #{counts.artists} artists, #{counts.albums} albums " <>
          "and #{counts.tracks} tracks, and #{gone} items are no longer on the server."
      )

      {:ok, empty(Map.put(counts, :removed, gone))}
    end
  end

  # A survey is an optimisation and a whole read is the truth, so one happens on a clock
  # however quiet the library looks. A week is long enough that the saving is nearly all
  # of it, and short enough that a rename is not wrong for a month.
  defp due_for_a_whole_read? do
    case Settings.fetch(@whole_read_key) do
      {:ok, %{value: value}} -> older_than_a_week?(value)
      {:error, _reason} -> true
    end
  end

  defp older_than_a_week?(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> DateTime.diff(DateTime.utc_now(), at, :second) >= @whole_read_after
      {:error, _reason} -> true
    end
  end

  defp whole_read_done do
    Settings.put(@whole_read_key, DateTime.to_iso8601(DateTime.utc_now()))

    :ok
  end

  # **The time of the read carries over, and it must.** `remove_unseen/1` removes each
  # row that this read did not see, and it reads `last_seen_at` against this time. A
  # read that continued with a new time would call every row that the read before the
  # interruption wrote a row that the server no longer has, and it would remove the
  # lot, with the marks of a person and the audio on the card.
  #
  # A point that is older than `@forget_after` gives a fresh read instead. The offset of
  # such a point names a place in a list that the server may have changed since, so
  # continuing from it would step over items that this device never read.
  defp start_point do
    case Checkpoint.read() do
      {:ok, %{started_at: started_at} = point} ->
        if DateTime.diff(DateTime.utc_now(), started_at, :second) < @forget_after do
          Logger.info(
            "Continuing the read of the Jellyfin library from #{point.kind} #{point.offset}."
          )

          point
        else
          fresh_point()
        end

      :error ->
        fresh_point()
    end
  end

  # Before the first read, so that a row which a page writes while a later page is
  # still arriving counts as one that this read saw.
  defp fresh_point, do: %{started_at: DateTime.utc_now(), kind: :artists, offset: 0}

  defp forget_point, do: Checkpoint.forget()

  # The kinds go in order, because an album names its artist and a track names its
  # album. A read that continues therefore starts at the kind of the point and takes
  # every kind after it from the beginning.
  #
  # **The counts are of this read alone.** A read that continues wrote none of what the
  # read before it wrote, so the number that it reports is smaller than the library.
  # Nothing reads those numbers but a person, and the log says which read they belong to.
  defp read_from(kind, offset, started_at, link) do
    kinds = Enum.drop_while(@kinds, &(&1 != kind))
    counts = Map.new(@kinds, &{&1, 0})

    Enum.reduce_while(kinds, {:ok, counts}, fn one, {:ok, acc} ->
      start = if one == kind, do: offset, else: 0

      case read(one, start, 0, started_at, link) do
        {:ok, written} -> {:cont, {:ok, Map.put(acc, one, written)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # **`Ash.BulkResult` carries no count of the rows that went**, and `return_records?`
  # would hold every one of them in memory for the sake of counting them. This reads
  # the number first, in the way that `PiFi.Cache.purge_all/1` says to.
  #
  # A container takes what it contains with it, through the reference of
  # `PiFi.Playback.Item`, so the number is of the rows that this query named and not
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

  defp read(kind, start, written, started_at, link) do
    Checkpoint.write(started_at, kind, start)

    case Server.page(kind, start, link) do
      {:ok, %{count: 0}} ->
        {:ok, written}

      {:ok, %{entries: entries, count: count, total: total}} ->
        next = start + count

        case fill(kind, entries) + written do
          all when next >= total -> {:ok, all}
          all -> read(kind, next, all, started_at, link)
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
