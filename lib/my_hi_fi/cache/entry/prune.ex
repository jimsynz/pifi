defmodule MyHiFi.Cache.Entry.Prune do
  @moduledoc """
  Removes the coldest entries until the cache is inside its limit.

  It reads the entries that an eviction may take, least recently used first, and it
  purges them one at a time until the total is under the limit. `purge_blob` of
  `AshStorage` removes the file and the row together.

  An entry that a caller marked with `keep?` stays, whatever its size and whatever
  its age. A cache that holds nothing else stays above the limit, and this reports
  that. The caller that marked those entries is the one that can release them, so
  this must not decide for it.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query
  require Logger

  alias MyHiFi.Cache

  @impl true
  def run(_input, _options, _context) do
    limit = Cache.limit()
    total = total_bytes()

    if total <= limit do
      {:ok, report(total, limit, 0, 0)}
    else
      {removed, freed} = remove(total - limit)
      now = total_bytes()

      Logger.info(
        "The cache removed #{removed} entries and #{div(freed, 1024)} KB. " <>
          "It holds #{div(now, 1024)} KB of #{div(limit, 1024)} KB."
      )

      {:ok, report(now, limit, removed, freed)}
    end
  end

  # It chooses the entries first and removes them in one bulk destroy. Choosing needs
  # a running total, which no query expression holds, and removing does not.
  defp remove(excess) do
    taking = choose(coldest(), excess, [], 0)
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

  defp coldest do
    Cache.Entry
    |> Ash.Query.for_read(:coldest)
    |> Ash.read!()
  end

  defp failed(errors) do
    Logger.warning("The cache could not remove every entry: #{inspect(errors)}")
    {0, 0}
  end

  defp total_bytes do
    Cache.Entry
    |> Ash.Query.for_read(:read)
    |> Ash.read!()
    |> Enum.map(&(&1.byte_size || 0))
    |> Enum.sum()
  end

  defp report(total, limit, removed, freed) do
    %{bytes: total, limit: limit, removed: removed, freed: freed, over?: total > limit}
  end
end
