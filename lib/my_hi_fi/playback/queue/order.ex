defmodule MyHiFi.Playback.Queue.Order do
  @moduledoc """
  Hold the places of the queue in order, with no gap and no two rows of one place.

  `position` counts from 0, and `MyHiFi.Playback.Queue` says that a caller cannot make
  a gap. A row that goes leaves one, so every write that takes a row out calls
  `close_gaps/0` after it.

  ## Why this is its own module

  Removing a row and moving a row both renumber the rows that follow. Keeping that
  arithmetic in one place stops the two from disagreeing about what a position means.

  **Renumbering never changes `playing?`.** The order of the queue and the row that
  plays are separate: a person who moves a row wants to change what comes next, not to
  change what they are listening to now.
  """

  alias MyHiFi.Playback.Queue

  @doc """
  Move one row to a given position, and renumber the rest around it.

  `position` counts from 0. A position outside the queue is clamped to the nearest end,
  so pressing "up" on the first row leaves it where it is instead of failing.

  **This does not change which row is playing.** A person who moves the playing row is
  still listening to it.

  It returns the row at its new position.
  """
  @spec move_to(Queue.t(), integer()) :: {:ok, Queue.t()} | {:error, term()}
  def move_to(row, position) do
    others = Enum.reject(sorted(), &(&1.id == row.id))
    place = position |> Kernel.max(0) |> Kernel.min(length(others))

    others
    |> List.insert_at(place, row)
    |> Enum.with_index()
    |> Enum.each(fn {one, index} ->
      if one.position != index, do: Ash.update!(one, %{position: index}, action: :set_position)
    end)

    Ash.get(Queue, row.id)
  end

  @doc """
  Number the rows again, from 0, in the order that they hold now.

  It gives the number of rows that moved.
  """
  @spec close_gaps() :: non_neg_integer()
  def close_gaps do
    sorted()
    |> Enum.with_index()
    |> Enum.reject(fn {row, index} -> row.position == index end)
    |> Enum.map(fn {row, index} ->
      Ash.update!(row, %{position: index}, action: :set_position)
    end)
    |> length()
  end

  defp sorted do
    Queue
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!()
  end
end
