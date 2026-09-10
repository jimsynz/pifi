defmodule MyHiFi.Playback.PlaylistEntry.Remove do
  @moduledoc """
  Takes one entry out of a playlist, and closes the gap that it leaves.

  The track stays in the catalogue, and every other playlist keeps it. A playlist
  names an item and it does not own one.
  """

  use Ash.Resource.Actions.Implementation

  alias MyHiFi.Playback.Playlist.Order
  alias MyHiFi.Playback.PlaylistEntry

  @impl true
  def run(input, _options, _context) do
    case Ash.get(PlaylistEntry, input.arguments.id) do
      {:ok, entry} ->
        :ok = Ash.destroy!(entry)
        Order.close_gaps(entry.playlist_id)

        {:ok, entry}

      {:error, _reason} ->
        {:error, :no_such_entry}
    end
  end
end
