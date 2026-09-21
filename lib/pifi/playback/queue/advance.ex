defmodule PiFi.Playback.Queue.Advance do
  @moduledoc """
  Move the mark on because a track ended, rather than because a person pressed next.

  **The difference is a repeat of one.** A track that ends under that mode plays again,
  and a person who presses next has asked for a different one. `PiFi.Playback.Queue.Move`
  is the press. See `PiFi.Playback.Queue.Mode`.

  A repeat of one leaves the mark where it is and answers the same row, which is what
  `PiFi.Player` needs: it starts whatever row this gives back.
  """

  use Ash.Resource.Actions.Implementation

  alias PiFi.Playback.Queue.Walk

  @impl true
  def run(_input, _options, _context) do
    with {:ok, playing} <- Walk.playing(),
         {:ok, wanted} <- Walk.after_playing(true) do
      moved(playing, wanted)
    end
  end

  # A repeat of one gives the row that is already marked, and rewriting the mark would
  # be two writes to the card for no change at all.
  defp moved(%{id: id}, %{id: id} = wanted), do: {:ok, wanted}

  defp moved(playing, wanted) do
    {:ok, _left} = Ash.update(playing, %{playing?: false}, action: :set_playing)
    Ash.update(wanted, %{playing?: true}, action: :set_playing)
  end
end
