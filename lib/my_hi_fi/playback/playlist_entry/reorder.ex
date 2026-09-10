defmodule MyHiFi.Playback.PlaylistEntry.Reorder do
  @moduledoc """
  Moves one entry of a playlist to another place.

  A person drags an entry, and `MyHiFi.Playback.Playlist.Order` does the write: it
  moves that entry and renumbers the rest of that playlist.
  """

  use Ash.Resource.Actions.Implementation

  alias MyHiFi.Playback.Playlist.Order
  alias MyHiFi.Playback.PlaylistEntry

  @impl true
  def run(input, _options, _context) do
    case Ash.get(PlaylistEntry, input.arguments.id) do
      {:ok, entry} -> Order.move_to(entry, input.arguments.position)
      {:error, _reason} -> {:error, :no_such_entry}
    end
  end
end
