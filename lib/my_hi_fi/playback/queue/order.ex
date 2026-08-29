defmodule MyHiFi.Playback.Queue.Order do
  @moduledoc """
  Hold the places of the queue in order, with no gap and no two rows of one place.

  `position` counts from 0, and `MyHiFi.Playback.Queue` says that a caller cannot make
  a gap. A row that goes leaves one, so every write that takes a row out calls
  `close_gaps/0` after it.

  ## Why this is its own module

  A person will drag a row to another place. That write moves one row and renumbers the
  rest, which is the same work that a removal does. One module holds it, so the two
  writes cannot disagree about what a place means.

  **A renumber never touches `playing?`.** The order of the queue and the row that plays
  are two separate things: a person who moves a row means to change what comes next, and
  not to change what they are listening to now.
  """

  alias MyHiFi.Playback.Queue

  @doc """
  Number the rows again, from 0, in the order that they hold now.

  It gives the number of rows that moved.
  """
  @spec close_gaps() :: non_neg_integer()
  def close_gaps do
    Queue
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!()
    |> Enum.with_index()
    |> Enum.reject(fn {row, index} -> row.position == index end)
    |> Enum.map(fn {row, index} ->
      Ash.update!(row, %{position: index}, action: :set_position)
    end)
    |> length()
  end
end
