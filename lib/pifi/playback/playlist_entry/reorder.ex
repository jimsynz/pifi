defmodule PiFi.Playback.PlaylistEntry.Reorder do
  @moduledoc """
  Moves one entry of a playlist to another place.

  A person drags an entry, and `PiFi.Playback.Playlist.Order` does the write: it
  moves that entry and renumbers the rest of that playlist.

  It refuses a playlist that a service owns, because the order is the order that the
  service gave and the next read would restore it. See
  `PiFi.Playback.Playlist.ensure_mine/1`.
  """

  use Ash.Resource.Actions.Implementation

  alias PiFi.Playback.Playlist
  alias PiFi.Playback.Playlist.Order
  alias PiFi.Playback.PlaylistEntry

  @impl true
  def run(input, _options, _context) do
    case Ash.get(PlaylistEntry, input.arguments.id) do
      {:ok, entry} ->
        with :ok <- Playlist.ensure_mine(entry.playlist_id),
             do: Order.move_to(entry, input.arguments.position)

      {:error, _reason} ->
        {:error, :no_such_entry}
    end
  end
end
