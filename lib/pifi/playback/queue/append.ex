defmodule PiFi.Playback.Queue.Append do
  @moduledoc """
  Add items after the last one of the queue.

  It moves no mark. A person who adds to a queue keeps hearing what plays.
  """

  use Ash.Resource.Actions.Implementation

  alias PiFi.Playback.Queue
  alias PiFi.Playback.Queue.Mode
  alias PiFi.Playback.Queue.Shuffle

  @impl true
  def run(input, _options, _context) do
    next = next_position()

    rows =
      input.arguments.item_ids
      |> Enum.with_index(next)
      |> Enum.map(fn {item_id, position} ->
        Queue
        |> Ash.Changeset.for_create(:create, %{item_id: item_id, position: position})
        |> Ash.create!()
      end)

    # **A row with no place in the shuffled order is a row the walk never reaches.**
    # `append` writes `position` and nothing else, so a track added to a shuffled queue
    # needs dealing on to the end of that order. See `PiFi.Playback.Queue.Shuffle`.
    if Mode.shuffle?(), do: Shuffle.deal_missing()

    {:ok, rows}
  end

  defp next_position do
    case Ash.read!(Queue) do
      [] -> 0
      rows -> rows |> Enum.map(& &1.position) |> Enum.max() |> Kernel.+(1)
    end
  end
end
