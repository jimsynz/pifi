defmodule MyHiFi.Playback.Playlist.ItemIds do
  @moduledoc """
  The items of one playlist, in the order that they play.

  `MyHiFi.Playback.play/2` takes this list, so a playlist plays through the queue and
  the player needs no knowledge of a playlist.
  """

  use Ash.Resource.Actions.Implementation

  alias MyHiFi.Playback.PlaylistEntry

  @impl true
  def run(input, _options, _context) do
    ids =
      PlaylistEntry
      |> Ash.Query.for_read(:in_order, %{playlist_id: input.arguments.playlist_id})
      |> Ash.read!()
      |> Enum.map(& &1.item_id)

    {:ok, ids}
  end
end
