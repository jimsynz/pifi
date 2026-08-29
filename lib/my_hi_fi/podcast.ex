defmodule MyHiFi.Podcast do
  @moduledoc """
  Podcasts.

  A show is one podcast, and an episode is one recording of it. The Podcast Index
  finds a show, and the feed of the publisher gives the episodes. See
  `MyHiFi.Podcast.Feed`.

  This domain holds no episode and no title. `MyHiFi.Playback.Item` holds every
  playable thing of this firmware, and `MyHiFi.Podcast.Fill` writes the shows and the
  episodes into it. What stays here belongs to the reading of a feed alone: the address
  of the feed, the identifier of the index, and what the last read gave.

  The two sources of a show carry different weight. The feed wins, because the
  publisher owns it. The index fills a show that no feed read yet, and it gives
  nothing to a show that a feed already described.
  """

  use Ash.Domain, otp_app: :my_hi_fi

  resources do
    resource MyHiFi.Podcast.Show do
      define :list_shows, action: :read
      define :get_show, action: :read, get_by: [:id]
      define :get_show_by_feed_url, action: :read, get_by: [:feed_url]
      define :subscribed_shows, action: :subscriptions
      define :upsert_show_from_feed, action: :upsert_from_feed
      define :upsert_show_from_index, action: :upsert_from_index
      define :set_show_item, action: :set_item
      define :record_show_error, action: :record_error
      define :destroy_show, action: :destroy
      define :read_trending_shows, action: :read_trending
      define :refresh_all_shows, action: :refresh_all
    end
  end
end
