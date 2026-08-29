defmodule MyHiFi.Repo.Migrations.DropStations do
  @moduledoc """
  Remove the table of `MyHiFi.Radio.Station`.

  Every playable thing is a `MyHiFi.Playback.Item` now, and internet radio reads the
  catalogue. `MyHiFi.Radio.CarryFavourites` runs before this one, so the stations that
  a person marked are already items.

  Ash writes no migration for a resource that a release removes, so this one is by
  hand.
  """

  use Ecto.Migration

  def up, do: drop_if_exists(table(:stations))

  def down do
    raise Ecto.MigrationError,
      message:
        "The station table is gone, and the catalogue holds the stations. " <>
          "Read the list again from Radio Browser."
  end
end
