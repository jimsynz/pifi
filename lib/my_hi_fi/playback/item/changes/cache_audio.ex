defmodule MyHiFi.Playback.Item.Changes.CacheAudio do
  @moduledoc """
  Read the audio of this item on to the card.

  `MyHiFi.Playback.FavouriteAudio` holds the rule and does the reading, so this runs
  after the update and it changes no attribute here.

  A read that fails writes a line in the log and raises nothing, so the job succeeds
  either way. A retry would ask the same server again and get the same answer, and
  `MyHiFi.Jellyfin.Sync.Favourites` reads it again when the network answers.
  """

  use Ash.Resource.Change

  alias MyHiFi.Playback.FavouriteAudio

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, item ->
      FavouriteAudio.read(item)

      {:ok, item}
    end)
  end
end
