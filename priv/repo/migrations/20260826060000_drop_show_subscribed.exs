defmodule PiFi.Repo.Migrations.DropShowSubscribed do
  @moduledoc """
  Remove `subscribed` of a show.

  A subscription is a mark on the item of the show now, because that is what a person
  did and `PiFi.Playback.Item` holds all of that.

  This runs after `PiFi.Podcast.CarryPlaces`, which reads the column and writes a
  marked item for each subscribed show. Ash writes no removal of its own: it comments
  one out to keep a person from losing data by accident.
  """

  use Ecto.Migration

  def up do
    alter table(:podcast_shows) do
      remove :subscribed
    end
  end

  def down do
    alter table(:podcast_shows) do
      add :subscribed, :boolean, null: false, default: false
    end
  end
end
