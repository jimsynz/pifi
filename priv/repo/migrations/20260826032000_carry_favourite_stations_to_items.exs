defmodule MyHiFi.Repo.Migrations.CarryFavouriteStationsToItems do
  @moduledoc """
  Keep the stations that a person marked. See `MyHiFi.Radio.CarryFavourites`.

  **This must run after the migration that makes `playback_items`, and before the one
  that drops `stations`.** The number of this file puts it there. A number that comes
  earlier stops a device that holds a marked station, and it stops no other device,
  because the write happens one time for each marked station and not one time for the
  migration.
  """

  use Ecto.Migration

  def up, do: MyHiFi.Radio.CarryFavourites.run(repo())

  # A mark that came across stays on the item. The old table still holds it as well,
  # so nothing is lost by going back.
  def down, do: :ok
end
