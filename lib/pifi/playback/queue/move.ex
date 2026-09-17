defmodule PiFi.Playback.Queue.Move do
  @moduledoc """
  Move the mark to the row before or after the one that plays.

  The queue holds the order, and a source takes no part in it. This is why
  `PiFi.Source` needs no `next/1` and no `previous/1`.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias PiFi.Playback.Queue

  @impl true
  def run(input, _options, _context) do
    with {:ok, playing} <- playing(),
         {:ok, wanted} <- beside(playing, input.arguments.direction) do
      {:ok, _left} = Ash.update(playing, %{playing?: false}, action: :set_playing)
      Ash.update(wanted, %{playing?: true}, action: :set_playing)
    end
  end

  defp playing do
    case Ash.read_one!(Ash.Query.for_read(Queue, :playing)) do
      nil -> {:error, :no_more}
      row -> {:ok, row}
    end
  end

  defp beside(playing, direction) do
    wanted = playing.position + step(direction)

    case Ash.read!(Ash.Query.filter(Queue, position == ^wanted)) do
      [row] -> {:ok, row}
      [] -> {:error, :no_more}
    end
  end

  defp step(:next), do: 1
  defp step(:previous), do: -1
end
