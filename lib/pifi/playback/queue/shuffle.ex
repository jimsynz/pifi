defmodule PiFi.Playback.Queue.Shuffle do
  @moduledoc """
  Deals the queue a shuffled order, without moving a single row.

  It writes `shuffle_position` and never `position`, so a person who turns shuffle off
  gets back the order they made. See `PiFi.Playback.Queue.Mode`.

  ## The track that is playing stays where it is

  **A shuffle must not change what a person is hearing.** The row that plays keeps the
  first place in the new order, and the rest are dealt behind it, so pressing shuffle in
  the middle of a song leaves that song playing and changes only what follows.

  A queue with nothing playing is dealt whole, because there is nothing to interrupt.

  ## It deals every row, and a new row is dealt on to the end

  `append` writes no `shuffle_position`, so a track added while shuffle is on has none
  and would never be reached. `deal_missing/0` gives those rows a place after everything
  already dealt, which is what a person adding to a shuffled queue means: play it, but
  not before the things that were already waiting.
  """

  alias PiFi.Playback.Queue

  @doc """
  Give every row a place in a new shuffled order.

  The row that plays takes the first place, so the track a person is hearing carries on.
  """
  @spec deal() :: :ok
  def deal do
    rows = all()
    {playing, rest} = Enum.split_with(rows, & &1.playing?)

    (playing ++ Enum.shuffle(rest))
    |> Enum.with_index()
    |> Enum.each(fn {row, place} -> put(row, place) end)

    :ok
  end

  @doc """
  Give a place to any row that has none.

  A track added to a shuffled queue goes after everything already dealt.
  """
  @spec deal_missing() :: :ok
  def deal_missing do
    {dealt, fresh} = Enum.split_with(all(), &is_integer(&1.shuffle_position))

    next = dealt |> Enum.map(& &1.shuffle_position) |> highest()

    fresh
    |> Enum.shuffle()
    |> Enum.with_index(next)
    |> Enum.each(fn {row, place} -> put(row, place) end)

    :ok
  end

  @doc "Take the shuffled order away, so nothing reads it by accident."
  @spec forget() :: :ok
  def forget do
    Enum.each(all(), &put(&1, nil))

    :ok
  end

  defp all do
    Queue
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!()
  end

  defp highest([]), do: 0
  defp highest(places), do: Enum.max(places) + 1

  defp put(row, place) do
    Ash.update!(row, %{shuffle_position: place}, action: :set_shuffle_position)
  end
end
