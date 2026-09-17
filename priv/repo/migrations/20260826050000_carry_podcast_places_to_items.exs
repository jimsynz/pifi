defmodule PiFi.Repo.Migrations.CarryPodcastPlacesToItems do
  @moduledoc """
  Keep the subscriptions and the places of a person. See `PiFi.Podcast.CarryPlaces`.
  """

  use Ecto.Migration

  def up do
    _counts = PiFi.Podcast.CarryPlaces.run(repo())
    :ok
  end

  # What came across stays on the item, and the old tables still hold it as well.
  def down, do: :ok
end
