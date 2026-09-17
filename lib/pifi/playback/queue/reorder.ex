defmodule PiFi.Playback.Queue.Reorder do
  @moduledoc """
  Move one row of the queue to another position.

  A person presses a control beside a row, or drags it. Either way they choose a row and
  a position, and `PiFi.Playback.Queue.Order` does the write: it moves that row and
  renumbers the rest, which is the same arithmetic that a removal needs.

  **This does not change which row is playing.** Moving a row changes what comes next,
  not what a person is listening to now.
  """

  use Ash.Resource.Actions.Implementation

  alias PiFi.Playback.Queue
  alias PiFi.Playback.Queue.Order

  @impl true
  def run(input, _options, _context) do
    case Ash.get(Queue, input.arguments.id) do
      {:ok, row} -> Order.move_to(row, input.arguments.position)
      {:error, _reason} -> {:error, :no_such_row}
    end
  end
end
