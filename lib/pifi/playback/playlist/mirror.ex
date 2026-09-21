defmodule PiFi.Playback.Playlist.Mirror do
  @moduledoc """
  Makes one playlist read exactly as a service says it does.

  `PiFi.Playback.Playlist.Add` puts tracks on the end, which is what a person does.
  This replaces the whole list, which is what a sync does: a service gives an order and
  no history of how it changed, so there is nothing to apply and only a state to match.

  ## It writes nothing when nothing moved

  **An SD card has a finite number of writes**, and most reads of a library find a
  playlist that nobody touched. This compares the list it was given with the one on the
  card and returns early when they are the same, so an hourly sync of a library that
  nobody changed writes no row at all.

  `PiFi.Plex.Sync.Library` skips most of these before they get here, because a Plex
  playlist carries the moment it last changed and a read that finds that unmoved never
  asks for the tracks. This is the second guard, for a service that says nothing about
  when a playlist changed and for a playlist whose tracks moved without the time moving.

  ## Why it replaces rather than works out a difference

  A difference would have to compare every place to find that one track moved from 40th
  to 2nd, which is the whole list anyway, and then renumber everything between. The
  replacement is one destroy and one bulk create, it leaves no gap for
  `PiFi.Playback.Playlist.Order` to close, and a playlist that a person reordered on the
  server needs no special case.

  ## A track that this device has not read yet is absent

  The caller gives item identifiers, and it finds them by the reference that the service
  uses. A playlist that names a track of a library section this device has not read
  through yet is therefore shorter here than there, and the next sync writes the rest.
  That is the same rule the rest of the catalogue follows: a read that stops leaves what
  it has.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias PiFi.Playback.PlaylistEntry

  @impl true
  def run(input, _options, _context) do
    playlist_id = input.arguments.playlist_id
    wanted = input.arguments.item_ids

    if wanted == held(playlist_id) do
      {:ok, length(wanted)}
    else
      written(playlist_id, wanted)
    end
  end

  defp written(playlist_id, wanted) do
    clear(playlist_id)

    wanted
    |> Enum.with_index()
    |> Enum.each(fn {item_id, position} ->
      PlaylistEntry
      |> Ash.Changeset.for_create(:create, %{
        playlist_id: playlist_id,
        item_id: item_id,
        position: position
      })
      |> Ash.create!()
    end)

    {:ok, length(wanted)}
  end

  defp held(playlist_id) do
    PlaylistEntry
    |> Ash.Query.for_read(:in_order, %{playlist_id: playlist_id})
    |> Ash.read!()
    |> Enum.map(& &1.item_id)
  end

  # `:stream` and not one statement: the destroy of an entry is a plain row and the
  # bulk path would still read them, and this keeps the two writes the same shape.
  defp clear(playlist_id) do
    PlaylistEntry
    |> Ash.Query.filter(playlist_id == ^playlist_id)
    |> Ash.bulk_destroy!(:destroy, %{}, strategy: :stream, return_errors?: true)

    :ok
  end
end
