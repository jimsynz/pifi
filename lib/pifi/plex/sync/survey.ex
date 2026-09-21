defmodule PiFi.Plex.Sync.Survey do
  @moduledoc """
  Asks a Plex server what changed before reading anything.

  **A read of a whole library is 80 minutes and tens of thousands of writes**, and it
  ran every day whether a person had added a record or not. That is the write storm
  that everything else on this device queues behind: a measurement of one real library
  counted 63,010 tracks. Most days nothing changed at all.

  This asks three cheap questions per music section — one request each, reading a single
  entry so that the answer carries `totalSize` — and gives `PiFi.Plex.Sync.Library` one
  of three answers.

  - `:nothing` — the server holds as many as this device does, of every kind, and the
    newest of each is one this device already has. There is no work.
  - `{:added, entries}` — the server holds more, and walking the newest first reached
    something known. Only those are new, and nothing was removed. The entries come back
    with the finding, because the walk has already read them and a second request for
    the same rows would be the cost this module exists to avoid.
  - `:everything` — the server holds fewer than this device does, or the walk ran past
    its limit, or a kind could not be counted. Read the lot, and remove what the read
    does not see.

  ## What the counts cannot see

  **A library that gained one record and lost another counts the same.** The walk would
  find the new one, and the removed one would stay until something else forced a full
  read, so `PiFi.Plex.Sync.Library` runs one on a schedule of its own whatever this
  says. A count is an optimisation and never the whole truth.

  **An edit is invisible too.** A person who fixes the spelling of an album changes no
  count and adds nothing, so the new spelling arrives with the next full read. That is
  the trade for not writing 63,010 rows a day.

  ## Why it walks rather than trusting the difference

  The count says how many are new and not which. `addedAt:desc` puts the newest first,
  so the walk reads pages until it meets a reference that the catalogue holds, and
  everything before that is new. It stops at `@limit` references, because a library
  that gained thousands is one where reading the lot is the cheaper answer anyway.
  """

  require Ash.Query

  alias PiFi.Playback.Item
  alias PiFi.Plex.Fill
  alias PiFi.Plex.Server

  @kinds [:artists, :albums, :tracks]

  # Past this many new references, a full read costs less than the walk that found them
  # and answers the question of what went as well.
  @limit 2_000

  @typedoc "What a survey found, and what `PiFi.Plex.Sync.Library` should do about it."
  @type finding :: :nothing | {:added, %{atom() => [Server.entry()]}} | :everything

  @doc """
  The kinds that a survey counts, in the order that a read of them must happen.

      iex> PiFi.Plex.Sync.Survey.kinds()
      [:artists, :albums, :tracks]
  """
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "The number of new references past which a full read is the cheaper answer."
  @spec limit() :: pos_integer()
  def limit, do: @limit

  @doc """
  Ask what changed.

  See the module documentation for the three answers and what each one means.
  """
  @spec take([String.t()], map()) :: finding()
  def take(sections, link) do
    case counted(sections, link) do
      {:ok, counts} -> weigh(counts, sections, link)
      :error -> :everything
    end
  end

  # A count that the server will not give is a question this cannot answer, and the
  # safe answer to a question it cannot answer is to read everything.
  defp counted(sections, link) do
    Enum.reduce_while(@kinds, {:ok, %{}}, fn kind, {:ok, counts} ->
      case count_of(kind, sections, link) do
        {:ok, total} -> {:cont, {:ok, Map.put(counts, kind, total)}}
        {:error, _reason} -> {:halt, :error}
      end
    end)
  end

  defp count_of(kind, sections, link) do
    Enum.reduce_while(sections, {:ok, 0}, fn section, {:ok, sum} ->
      case Server.count(kind, section, link) do
        {:ok, total} -> {:cont, {:ok, sum + total}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # **Fewer on the server than on the card means something went**, and only a full read
  # can say what. More means additions, and the walk finds them. The same number of
  # every kind means there is very likely nothing to do, and the walk confirms it by
  # looking at the newest one.
  defp weigh(counts, sections, link) do
    if Enum.any?(@kinds, &(counts[&1] < held(&1))) do
      :everything
    else
      walked(sections, link)
    end
  end

  defp walked(sections, link) do
    Enum.reduce_while(@kinds, {:added, %{}}, fn kind, {:added, found} ->
      case new_entries(kind, sections, link) do
        {:ok, entries} -> {:cont, {:added, Map.put(found, kind, entries)}}
        :too_many -> {:halt, :everything}
        {:error, _reason} -> {:halt, :everything}
      end
    end)
    |> nothing_to_do()
  end

  defp nothing_to_do({:added, found}) do
    if Enum.all?(@kinds, &(found[&1] == [])), do: :nothing, else: {:added, found}
  end

  defp nothing_to_do(other), do: other

  defp new_entries(kind, sections, link) do
    Enum.reduce_while(sections, {:ok, []}, fn section, {:ok, found} ->
      case newest_until_known(kind, section, 0, [], link) do
        {:ok, refs} -> {:cont, {:ok, found ++ refs}}
        other -> {:halt, other}
      end
    end)
  end

  # **The newest first, and stop at the first one this device holds.** Everything before
  # it arrived since the last read. A page of the server is 50, so a library that gained
  # one record costs one request for each kind.
  defp newest_until_known(kind, section, start, found, link) do
    case Server.page(kind, section, start, link, sort: "addedAt:desc") do
      {:ok, %{count: 0}} ->
        {:ok, found}

      {:ok, %{entries: entries, count: count, total: total}} ->
        {fresh, known} = Enum.split_while(entries, &(not known?(&1.ref)))
        found = found ++ fresh

        cond do
          known != [] -> {:ok, found}
          length(found) > @limit -> :too_many
          start + count >= total -> {:ok, found}
          true -> newest_until_known(kind, section, start + count, found, link)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp known?(ref) do
    Item
    |> Ash.Query.filter(source == ^Fill.source() and source_ref == ^ref)
    |> Ash.Query.select([:id])
    |> Ash.read_one!()
    |> is_map()
  end

  # An artist is a container with no parent, an album is one with a parent, and a track
  # is a track. This is the same split that `PiFi.Source.Plex` browses by.
  # **The container that holds albums with no artist is this device's own invention**,
  # and the server has nothing matching it. Counting it would leave the card one ahead
  # of the server for ever, and every survey would answer `:everything`. See
  # `PiFi.Plex.Fill.unknown_artist_ref/0`.
  defp held(:artists) do
    unknown = Fill.unknown_artist_ref()

    Item
    |> Ash.Query.filter(
      source == ^Fill.source() and kind == :container and is_nil(parent_id) and
        source_ref != ^unknown
    )
    |> Ash.count!()
  end

  defp held(:albums) do
    Item
    |> Ash.Query.filter(source == ^Fill.source() and kind == :container and not is_nil(parent_id))
    |> Ash.count!()
  end

  defp held(:tracks) do
    Item
    |> Ash.Query.filter(source == ^Fill.source() and kind == :track)
    |> Ash.count!()
  end
end
