defmodule PiFi.Podcast.Show.Changes.Refresh do
  @moduledoc """
  Read the feed of this show.

  `PiFi.Podcast.Refresh` writes the show and the episodes through their own
  actions, so this runs after the update and it changes no attribute here.

  A read that fails writes `last_error` and raises nothing, so the job succeeds
  either way. A retry would read the same feed again and get the same answer, and
  the schedule reads it again in six hours.
  """

  use Ash.Resource.Change

  alias PiFi.Podcast.Refresh

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, show -> {:ok, Refresh.run(show)} end)
  end
end
