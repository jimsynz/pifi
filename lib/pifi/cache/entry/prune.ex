defmodule PiFi.Cache.Entry.Prune do
  @moduledoc """
  Removes the coldest entries until the cache is inside its limit.

  It reads the entries that an eviction may take, least recently used first, and it
  purges them one at a time until the total is under the limit. `purge_blob` of
  `AshStorage` removes the file and the row together.

  It flushes the used marks that `PiFi.Cache.Touches` holds before it reads, because
  those marks are what the order below is made of.

  An entry that a caller marked with `keep?` stays, whatever its size and whatever
  its age. A cache that holds nothing else stays above the limit, and this reports
  that. The caller that marked those entries is the one that can release them, so
  this must not decide for it.

  ## The limit, and the room that a caller asks for

  `want_bytes` moves the target below the limit, and it changes nothing else: the
  same order, the same `keep?` rule, one eviction for the whole card.

  **A limit alone cannot make room, and that is why the argument is here.** The limit
  of this cache is the free space of the partition, less a reserve, so it falls as the
  cache grows and the two meet. A cache at that point holds a total that is inside its
  limit, so an eviction with no target removes nothing at all, and a caller that needs
  40 MB for one file is told that the card is full while gigabytes of cold artwork sit
  beside it. `PiFi.Playback.FavouriteAudio` names the size of the track that it is
  about to read, and the coldest entries then go.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query
  require Logger

  alias PiFi.Cache

  @impl true
  def run(input, _options, _context) do
    # **The used marks that a buffer holds decide this order, so they must be on the
    # card before it reads.** A stale row could put the picture that a screen is drawing
    # at the cold end of the list. See `PiFi.Cache.Touches`.
    Cache.Touches.flush()

    limit = Cache.limit()
    target = Kernel.max(limit - input.arguments.want_bytes, 0)
    total = Cache.bytes()

    if total <= target do
      {:ok, report(total, limit, 0, 0)}
    else
      {removed, freed} = remove(total - target, Map.get(input.arguments, :colder_than))
      now = Cache.bytes()

      Logger.info(
        "The cache removed #{removed} entries and #{div(freed, 1024)} KB. " <>
          "It holds #{div(now, 1024)} KB of #{div(limit, 1024)} KB."
      )

      {:ok, report(now, limit, removed, freed)}
    end
  end

  # It chooses the entries first and removes them in one bulk destroy. Choosing needs
  # a running total, which no query expression holds, and removing does not.
  defp remove(excess, colder_than) do
    taking = choose(coldest(colder_than), excess, [], 0)
    ids = Enum.map(taking, & &1.id)
    freed = taking |> Enum.map(&(&1.byte_size || 0)) |> Enum.sum()

    case purge(ids) do
      :ok -> {length(ids), freed}
      {:error, errors} -> failed(errors)
    end
  end

  defp purge([]), do: :ok

  defp purge(ids) do
    Cache.Entry
    |> Ash.Query.filter(id in ^ids)
    |> Cache.purge_all()
  end

  # Enough has gone, so the rest stay however cold they are.
  defp choose(_entries, excess, taking, freed) when freed >= excess, do: Enum.reverse(taking)

  defp choose([], _excess, taking, _freed), do: Enum.reverse(taking)

  defp choose([entry | rest], excess, taking, freed) do
    choose(rest, excess, [entry | taking], freed + (entry.byte_size || 0))
  end

  defp coldest(colder_than) do
    Cache.Entry
    |> Ash.Query.for_read(:coldest, %{colder_than: colder_than})
    |> Ash.read!()
  end

  defp failed(errors) do
    Logger.warning("The cache could not remove every entry: #{inspect(errors)}")
    {0, 0}
  end

  defp report(total, limit, removed, freed) do
    %{bytes: total, limit: limit, removed: removed, freed: freed, over?: total > limit}
  end
end
