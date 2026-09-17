defmodule PiFi.Plex.Sync.Library do
  @moduledoc """
  Copies the library of a Plex server into the catalogue.

  `PiFi.AutoSync` runs this when the source is in use, the device has a link, and
  the network answers. A person can also press a control on the settings page.

  ## It reads a page at a time

  A library has tens of thousands of tracks, and this board has 363.9 MB. The read
  therefore asks for one page, writes it, and lets it go. Nothing here keeps the
  library, and the largest thing in memory is one page of 50 entries.

  The three kinds go in order, because an album names its artist and a track names its
  album. `PiFi.Plex.Fill` reads the parent of each page out of the catalogue, so the
  artists must be there before the albums arrive.

  **A Plex server holds a section for each library, and each kind reads every music
  section before the next kind begins.** A household with a section of records and a
  section of audiobooks therefore gets the artists of both, then the albums of both,
  then the tracks of both. The order matters for the same reason as above: an album of
  one section may name an artist of another, and a read that finished one section
  before it started the next would lose that link.

  A read that fails leaves the catalogue as it stands. A person still browses what the
  device has read, and the next run reads the rest.

  ## A read that stops continues where it stopped

  A large library takes more than an hour, and this device stops often: it goes into
  standby, a person takes the power away, and a new firmware restarts it.
  `Oban.Lifeline` gives such a job back to the queue, and a read that began again from
  nothing would ask the server for the whole library a second time.

  `PiFi.Plex.Sync.Checkpoint` therefore keeps the kind, the section and the offset
  that the read has reached, and a read that finds one continues from it. See
  `start_point/1` for the two things that make this safe: the time of the first read
  carries over, and a point that is too old is left alone.

  ## What the read did not see, it removes

  A server that no longer has an album must not leave that album in the list for ever.
  Each row that a read writes carries `last_seen_at`, and a read that finishes removes
  every row of this source that is older than the moment it began.

  **It removes nothing unless every read worked.** That one rule is what makes this
  safe, and it is the only thing that does: a read that stops half way has seen no
  track, and a remover that ran then would empty the catalogue. The `with` below
  therefore stops the removal, and a failure of any kind leaves every row where it is.
  The same is true of a device that this source is out of use on, and of one that has
  no link: `run/3` answers before any of this.

  **An answer of nothing empties the catalogue, and that is the choice.** A fault that
  names itself removes nothing: no network gives an error, a token that stopped working
  gives 401, and a library that went gives 404, so the `with` never reaches the
  removal. An answer of 200 with no item is not a fault, and a person who cannot reach
  their library can play nothing of it, so the device follows the server. A Plex server
  that a person rebuilt answers that way while it reads its own files, and the next
  read writes the library again.

  **A server with no music section is not the same as a server with none of it.** A
  read that found no section at all stops before it removes anything, because a person
  who pointed the device at the wrong server of their household must not lose the
  library that they already read.

  **A mark does not hold a row back, and neither does a file on the card.** A person
  who marked an album that their server no longer has loses that mark, because the
  catalogue follows the server. A track that goes gives up its audio as it goes,
  through the destroy of `PiFi.Playback.Item`, and the key of a download is the
  identifier of the row, so a later read writes a new row and reaches none of the old
  files.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query
  require Logger

  alias PiFi.Event
  alias PiFi.Playback.Item
  alias PiFi.Plex.Fill
  alias PiFi.Plex.Server
  alias PiFi.Plex.Sync.Checkpoint
  alias PiFi.Source

  @kinds [:artists, :albums, :tracks]

  # How old a point may be and still serve. A read takes about an hour, and
  # `PiFi.AutoSync` runs the work again within the hour, so a point of any use is
  # hours old at the most. Six hours leaves room for a device that a person switched
  # off for an evening, and it refuses a point from another day.
  @forget_after 6 * 60 * 60

  # A person who takes this source out of use expects the device to ask the server for
  # nothing. See `PiFi.Source.enabled?/1`.
  @impl true
  def run(_input, _options, _context) do
    if Source.enabled?(Source.Plex) and Server.configured?() do
      sync()
    else
      {:ok, %{artists: 0, albums: 0, tracks: 0, removed: 0, skipped?: true}}
    end
  end

  defp sync do
    with {:ok, link} <- Server.link(),
         {:ok, sections} <- Server.sections(link),
         {:ok, sections} <- music(sections),
         point = start_point(sections),
         {:ok, counts} <- read_from(point, sections, link) do
      gone = remove_unseen(point.started_at)
      Checkpoint.forget()
      announce()

      Logger.info(
        "The Plex library gave #{counts.artists} artists, #{counts.albums} albums " <>
          "and #{counts.tracks} tracks, and #{gone} items are no longer on the server."
      )

      {:ok, Map.merge(counts, %{removed: gone, skipped?: false})}
    end
  end

  # A server that holds no music is a server that this device cannot read, and it is
  # not a server whose music went. See the moduledoc.
  defp music([]), do: {:error, :no_music_section}
  defp music(sections), do: {:ok, sections}

  # **The time of the read carries over, and it must.** `remove_unseen/1` removes each
  # row that this read did not see, and it reads `last_seen_at` against this time. A
  # read that continued with a new time would call every row that the read before the
  # interruption wrote a row that the server no longer has, and it would remove the
  # lot, with the marks of a person and the audio on the card.
  #
  # A point that is older than `@forget_after` gives a fresh read instead. The offset of
  # such a point names a place in a list that the server may have changed since, so
  # continuing from it would step over items that this device never read.
  #
  # **A point whose section the server no longer lists gives a fresh read too.** A
  # person who removed a library between two runs would otherwise send the read to a
  # section that answers 404, and every later kind would go unread.
  defp start_point(sections) do
    case Checkpoint.read() do
      {:ok, point} ->
        if usable?(point, sections) do
          Logger.info(
            "Continuing the read of the Plex library from " <>
              "#{point.kind} #{point.offset} of section #{point.section}."
          )

          point
        else
          fresh_point(sections)
        end

      :error ->
        fresh_point(sections)
    end
  end

  defp usable?(%{started_at: started_at, section: section}, sections) do
    DateTime.diff(DateTime.utc_now(), started_at, :second) < @forget_after and
      section in sections
  end

  # Before the first read, so that a row which a page writes while a later page is
  # still arriving counts as one that this read saw.
  defp fresh_point(sections) do
    %{
      started_at: DateTime.utc_now(),
      kind: :artists,
      section: List.first(sections),
      offset: 0
    }
  end

  # The work of a whole read is one list of `{kind, section}` pairs, in the order that
  # the moduledoc gives. A read that continues drops every pair before the one that the
  # point names, and it starts that pair at the offset of the point.
  #
  # **The counts are of this read alone.** A read that continues wrote none of what the
  # read before it wrote, so the number that it reports is smaller than the library.
  # Nothing reads those numbers but a person, and the log says which read they belong
  # to.
  defp read_from(point, sections, link) do
    steps =
      for kind <- @kinds, section <- sections, do: {kind, section}

    steps = Enum.drop_while(steps, &(&1 != {point.kind, point.section}))
    counts = Map.new(@kinds, &{&1, 0})

    Enum.reduce_while(steps, {:ok, counts}, fn {kind, section} = step, {:ok, acc} ->
      start = if step == {point.kind, point.section}, do: point.offset, else: 0

      case read(kind, section, start, 0, point.started_at, link) do
        {:ok, written} -> {:cont, {:ok, Map.update!(acc, kind, &(&1 + written))}}
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

  defp read(kind, section, start, written, started_at, link) do
    Checkpoint.write(started_at, kind, section, start)

    case Server.page(kind, section, start, link) do
      {:ok, %{count: 0}} ->
        {:ok, written}

      {:ok, %{entries: entries, count: count, total: total}} ->
        next = start + count

        case fill(kind, entries) + written do
          all when next >= total -> {:ok, all}
          all -> read(kind, section, next, all, started_at, link)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fill(:artists, entries), do: Fill.artists(entries)
  defp fill(:albums, entries), do: Fill.albums(entries)
  defp fill(:tracks, entries), do: Fill.tracks(entries)

  # A page that shows a branch of this source reads it again. The read takes minutes on
  # a large library, so a person is often looking at the catalogue while this writes it.
  defp announce do
    Event.publish(:source, %Event.Source.Changed{source: Source.Plex, ref: :library})
  end
end
