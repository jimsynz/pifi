defmodule PiFi.Playback.PlaylistEntry.Remove do
  @moduledoc """
  Takes one entry out of a playlist, and closes the gap that it leaves.

  The track stays in the catalogue, and every other playlist keeps it. A playlist
  names an item and it does not own one.

  It refuses a playlist that a service owns: the next read of that service would put
  the track back. See `PiFi.Playback.Playlist.ensure_mine/1`.
  """

  use Ash.Resource.Actions.Implementation

  alias PiFi.Playback.Playlist
  alias PiFi.Playback.Playlist.Order
  alias PiFi.Playback.PlaylistEntry

  @impl true
  def run(input, _options, _context) do
    case Ash.get(PlaylistEntry, input.arguments.id) do
      {:ok, entry} ->
        with :ok <- Playlist.ensure_mine(entry.playlist_id) do
          :ok = Ash.destroy!(entry)
          Order.close_gaps(entry.playlist_id)

          {:ok, entry}
        end

      {:error, _reason} ->
        {:error, :no_such_entry}
    end
  end
end
