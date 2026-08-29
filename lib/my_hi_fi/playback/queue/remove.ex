defmodule MyHiFi.Playback.Queue.Remove do
  @moduledoc """
  Take one row out of the queue.

  A person presses the control beside a row. A track that reaches its end stays, and
  the mark moves past it, so a person can go back to what they heard. See
  `MyHiFi.Playback.Queue.Move`.

  ## The mark

  This does not move the mark, and a caller that removes the row that plays decides
  what plays next. Only the caller knows what a person meant.
  """

  use Ash.Resource.Actions.Implementation

  alias MyHiFi.Playback.Queue
  alias MyHiFi.Playback.Queue.Order

  @impl true
  def run(input, _options, _context) do
    case Ash.get(Queue, input.arguments.id) do
      {:ok, row} ->
        :ok = Ash.destroy!(row)
        Order.close_gaps()

        {:ok, row}

      {:error, _reason} ->
        {:error, :no_such_row}
    end
  end
end
