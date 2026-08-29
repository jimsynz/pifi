defmodule MyHiFi.Repo.Migrations.LinkCarriedShowsToItems do
  @moduledoc """
  Join each show to its item, for the shows that `MyHiFi.Podcast.CarryPlaces` carried.

  The carry writes an item for each show that a person subscribed to, and it leaves
  `podcast_shows.item_id` empty. Every read that fills the episodes goes through that
  key: `MyHiFi.Podcast.Show.subscriptions` finds a subscription through it, and
  `MyHiFi.Source.Podcasts` finds the feed behind a container through it. A show with no
  key therefore never reads its feed, and each episode of it keeps the title and the
  place that the carry wrote, and no address. The player then gets an item that names
  no format, and it stops.

  A show and its item meet at the address of the feed, because `MyHiFi.Podcast.Fill`
  makes the address the `source_ref` of the item. This makes the key from that.

  It names only tables that this release holds, so it repairs a device that already
  ran the carry, and it does the same work for a device that runs the carry later.
  """

  use Ecto.Migration

  def up do
    execute("""
    UPDATE podcast_shows
    SET item_id = (
      SELECT id FROM playback_items
      WHERE source = 'podcasts' AND source_ref = podcast_shows.feed_url
    )
    WHERE item_id IS NULL
      AND EXISTS (
        SELECT 1 FROM playback_items
        WHERE source = 'podcasts' AND source_ref = podcast_shows.feed_url
      )
    """)
  end

  # A key that this made is the key that a feed read makes, so there is nothing to
  # take back. A removal here would also break a show that a search linked.
  def down, do: :ok
end
