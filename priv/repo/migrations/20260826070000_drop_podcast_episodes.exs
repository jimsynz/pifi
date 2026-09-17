defmodule PiFi.Repo.Migrations.DropPodcastEpisodes do
  @moduledoc """
  Remove the table of `PiFi.Podcast.Episode`, and the columns of a show that the
  item holds.

  Every playable thing is a `PiFi.Playback.Item` now. `PiFi.Podcast.Show` keeps the
  address of the feed, the identifier of the index and what the last read gave, and
  everything that a person reads or does is on the item.

  `PiFi.Podcast.CarryPlaces` runs before this one, so the subscriptions and the
  places of a person are already items.

  Ash writes no migration for a resource that a release removes, and it comments out
  the removal of a column, so this one is by hand.
  """

  use Ecto.Migration

  def up do
    drop_if_exists(table(:podcast_episodes))

    alter table(:podcast_shows) do
      remove :title
      remove :author
      remove :description
      remove :artwork_url
    end
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "The episodes are items of the catalogue now. " <>
          "Read the feed of each show again."
  end
end
