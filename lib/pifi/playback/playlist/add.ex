defmodule PiFi.Playback.Playlist.Add do
  @moduledoc """
  Puts items on the end of one playlist.

  The order that a person sees is the order that arrives, so this writes the items in
  the order of the list that it gets. **A track that the playlist already carries goes
  in again**, because a person who asks for one twice means it.

  It refuses a playlist that a service owns, because the next read of that service
  would write the addition away. See `PiFi.Playback.Playlist.ensure_mine/1`.

  It returns the entries that it wrote.
  """

  use Ash.Resource.Actions.Implementation

  alias PiFi.Playback.Playlist
  alias PiFi.Playback.Playlist.Order
  alias PiFi.Playback.PlaylistEntry

  @impl true
  def run(input, _options, _context) do
    playlist_id = input.arguments.playlist_id

    with :ok <- Playlist.ensure_mine(playlist_id), do: added(input, playlist_id)
  end

  defp added(input, playlist_id) do
    next = Order.next_position(playlist_id)

    entries =
      input.arguments.item_ids
      |> Enum.with_index(next)
      |> Enum.map(fn {item_id, position} ->
        PlaylistEntry
        |> Ash.Changeset.for_create(:create, %{
          playlist_id: playlist_id,
          item_id: item_id,
          position: position
        })
        |> Ash.create!()
      end)

    {:ok, entries}
  end
end
