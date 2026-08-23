defmodule MyHiFi.Podcast.Episode do
  @moduledoc """
  One recording of a podcast.

  `MyHiFi.Podcast.Feed` gives these, and the `<guid>` of the item identifies one
  inside its show. An item with no `<guid>` uses the address of its audio instead,
  so every episode holds one.

  An episode is not live, so it has a length and a place. `position_ms` holds where
  a person stopped, and `played?` says that it reached its end.
  """

  use Ash.Resource,
    otp_app: :my_hi_fi,
    domain: MyHiFi.Podcast,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "podcast_episodes"
    repo MyHiFi.Repo
  end

  actions do
    default_accept []

    # The refresh job keeps the newest 200 episodes of a show, and it removes the
    # rest, because the database is on an SD card.
    defaults [:read]

    destroy :destroy do
      primary? true

      # The change reads and writes another table, so this destroy is not one
      # statement. A cache row of a record that is going is worth that.
      require_atomic? false

      # The join of the cache holds no key to this record, because no column of the
      # cache names a resource. This host therefore removes its own rows. It removes
      # no entry: one picture serves many records, and the eviction reclaims a file
      # that nothing names any more. See `MyHiFi.Cache.Attachment`.
      change {MyHiFi.Cache.Attachment.Changes.DetachRecord, type: "episode"}
    end

    read :by_show do
      description "List the episodes of one show, the newest one first."

      argument :show_id, :uuid, allow_nil?: false

      filter expr(show_id == ^arg(:show_id))
      prepare build(sort: [published_at: :desc])
    end

    create :upsert_from_feed do
      description """
      Write an episode from its feed.

      The refresh job calls this for each item that the feed holds. `show_id` and
      `guid` identify the episode, so a second read updates the row that the first
      one wrote.

      It leaves `position_ms` and `played?` alone, because those belong to the
      person and not to the publisher.
      """

      upsert? true
      upsert_identity :guid_of_show

      accept [
        :show_id,
        :guid,
        :title,
        :subtitle,
        :description,
        :audio_url,
        :mime_type,
        :byte_length,
        :duration_ms,
        :published_at,
        :artwork_url
      ]
    end

    update :store_position do
      description """
      Note where a person stopped.

      The player calls this when it stops and when it enters standby. The next play
      of this episode starts from here.
      """

      accept [:position_ms]
    end

    update :mark_played do
      description """
      Note that the episode reached its end.

      The position returns to the start, so a person who plays it again hears it
      from the beginning.
      """

      change set_attribute(:played?, true)
      change set_attribute(:position_ms, 0)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :guid, :string do
      description "The `<guid>` of the item, or the address of the audio for an item that holds none."
      allow_nil? false
      public? true
      constraints min_length: 1
    end

    attribute :title, :string do
      public? true
    end

    attribute :subtitle, :string do
      description "From `itunes:subtitle`. A publisher writes it for 25% of the episodes."
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :audio_url, :string do
      description "The `url` of the enclosure. This is what the player plays."
      allow_nil? false
      public? true
      constraints min_length: 1
    end

    attribute :mime_type, :string do
      description """
      The `type` of the enclosure. 8771 of the 8773 episodes of the measurement hold
      `audio/mpeg`, and the source refuses the rest until this firmware holds a
      demultiplexer for MP4.
      """

      public? true
    end

    attribute :byte_length, :integer do
      description """
      The `length` of the enclosure, as the feed writes it. It is absent for 39% of
      the episodes of the measurement, and it is wrong for many of the rest: one
      episode of 5 named 14,165,913 bytes and sent 7,270,145. A resume therefore
      reads the bitrate of the audio instead. See `MyHiFi.Player.Mp3`.
      """

      public? true
    end

    attribute :duration_ms, :integer do
      description "From `itunes:duration`. The progress bar needs it."
      public? true
    end

    attribute :published_at, :utc_datetime_usec do
      description "From `<pubDate>`, as RFC 2822. The list sorts by it."
      public? true
    end

    attribute :artwork_url, :string do
      description "From `itunes:image` of the item. The cover of the show serves an episode that holds none."
      public? true
    end

    attribute :position_ms, :integer do
      description "Where the person stopped. The player writes it, and a resume reads it."
      allow_nil? false
      default 0
      public? true
    end

    attribute :played?, :boolean do
      description "The episode reached its end."
      source :played
      allow_nil? false
      default false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :show, MyHiFi.Podcast.Show do
      allow_nil? false
      public? true
      # The refresh job writes 200 episodes of one show at a time, and it holds the
      # show already. Accepting the key costs one field, and managing the
      # relationship would cost a read for each episode.
      attribute_writable? true
    end
  end

  identities do
    identity :guid_of_show, [:show_id, :guid] do
      description """
      One row for each item of each feed, so a second read updates and does not
      duplicate. A `guid` is unique inside its feed, and not between feeds, so the
      show belongs in this identity.
      """
    end
  end
end
