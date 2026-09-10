defmodule MyHiFi.Playback.Queue.NextUp do
  @moduledoc """
  The row after the one that plays. It moves no mark.

  `MyHiFi.Playback.Queue.Move` answers which row is next by making it the one that
  plays. The player needs the answer while a person is still in the middle of a
  track, so that it can read the audio of that row before it is needed. See
  `MyHiFi.Player.Prefetch`.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias MyHiFi.Playback.Queue

  @impl true
  def run(_input, _options, _context) do
    with {:ok, playing} <- playing(),
         [row] <- Ash.read!(Ash.Query.filter(Queue, position == ^(playing.position + 1))) do
      {:ok, row}
    else
      _other -> {:error, :no_more}
    end
  end

  defp playing do
    case Ash.read_one!(Ash.Query.for_read(Queue, :playing)) do
      nil -> {:error, :no_more}
      row -> {:ok, row}
    end
  end
end
