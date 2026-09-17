defmodule PiFi.Playback.Queue.Append do
  @moduledoc """
  Add items after the last one of the queue.

  It moves no mark. A person who adds to a queue keeps hearing what plays.
  """

  use Ash.Resource.Actions.Implementation

  alias PiFi.Playback.Queue

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

    {:ok, rows}
  end

  defp next_position do
    case Ash.read!(Queue) do
      [] -> 0
      rows -> rows |> Enum.map(& &1.position) |> Enum.max() |> Kernel.+(1)
    end
  end
end
