defmodule MyHiFi.Playback.Playlist.Order do
  @moduledoc """
  Keeps the places of one playlist in order, with no gap and no two entries of one
  place.

  `position` counts from 0. An entry that goes leaves a gap, so every write that takes
  one out calls `close_gaps/1` after it.

  ## Why this is not `MyHiFi.Playback.Queue.Order`

  The arithmetic is the same and the tables are not. A queue is one list on ETS, so
  that module reads every row of the table. A playlist is one of many on SQLite, so
  each read here names a playlist and a write of one playlist leaves every other one
  alone.

  The two hold the same two functions with the same names, so a third list of this
  firmware is the moment to make one module of them.

  ## A removal of the track leaves a gap, and the next write closes it

  `MyHiFi.Playback.PlaylistEntry` names the item with a reference, and a removal of
  the item takes the entry with it. Nothing calls `close_gaps/1` for such a removal,
  so a playlist that loses its first track carries the places 1, 2 and 3. A reader
  sorts on the place and never counts on it, so the order stays correct, and the next
  drag or removal numbers them again.
  """

  alias MyHiFi.Playback.PlaylistEntry

  @doc """
  Move one entry to a given place, and renumber the rest around it.

  `position` counts from 0. A place outside the playlist is clamped to the nearest
  end, so a drag above the first entry leaves it where it is.

  It returns the entry at its new place.
  """
  @spec move_to(PlaylistEntry.t(), integer()) ::
          {:ok, PlaylistEntry.t()} | {:error, term()}
  def move_to(entry, position) do
    others = Enum.reject(sorted(entry.playlist_id), &(&1.id == entry.id))
    place = position |> Kernel.max(0) |> Kernel.min(length(others))

    others
    |> List.insert_at(place, entry)
    |> Enum.with_index()
    |> Enum.each(fn {one, index} ->
      if one.position != index, do: Ash.update!(one, %{position: index}, action: :set_position)
    end)

    Ash.get(PlaylistEntry, entry.id)
  end

  @doc """
  Number the entries of one playlist again, from 0, in the order that they stand now.

  It returns the number of entries that moved.
  """
  @spec close_gaps(Ash.UUID.t()) :: non_neg_integer()
  def close_gaps(playlist_id) do
    playlist_id
    |> sorted()
    |> Enum.with_index()
    |> Enum.reject(fn {entry, index} -> entry.position == index end)
    |> Enum.map(fn {entry, index} ->
      Ash.update!(entry, %{position: index}, action: :set_position)
    end)
    |> length()
  end

  @doc """
  The place that the next entry of one playlist takes.
  """
  @spec next_position(Ash.UUID.t()) :: non_neg_integer()
  def next_position(playlist_id) do
    case sorted(playlist_id) do
      [] -> 0
      entries -> entries |> List.last() |> Map.fetch!(:position) |> Kernel.+(1)
    end
  end

  defp sorted(playlist_id) do
    PlaylistEntry
    |> Ash.Query.for_read(:in_order, %{playlist_id: playlist_id})
    |> Ash.read!()
  end
end
