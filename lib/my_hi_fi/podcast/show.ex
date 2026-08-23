defmodule MyHiFi.Podcast.Show do
  @moduledoc """
  One podcast.

  A show arrives in two ways. The Podcast Index gives one that a person found by a
  search, and `MyHiFi.Podcast.Feed` gives one that a person named by its address.
  `feed_url` identifies the show in both, so the two never make a second row for
  the same podcast.

  A show that a person subscribed to holds `subscribed?`. The refresh job reads
  those alone, so a search costs the device nothing later.
  """

  use Ash.Resource,
    otp_app: :my_hi_fi,
    domain: MyHiFi.Podcast,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshOban]

  sqlite do
    table "podcast_shows"
    repo MyHiFi.Repo
  end

  oban do
    scheduled_actions do
      # A publisher writes an episode, and no publisher writes one each hour. Four
      # reads of each feed in a day is often enough for a person who listens each
      # day, and it reads the subscribed shows only.
      schedule :refresh_all, "0 */6 * * *" do
        action :refresh_all
        worker_module_name MyHiFi.Podcast.Show.Workers.RefreshAll
        queue :default
        max_attempts 3
      end
    end
  end

  actions do
    default_accept []

    # A search writes a show that a person may never open again, so something must
    # be able to remove one. Section 7 of `docs/podcasts-plan.md` decides whether a
    # search writes a row at all.
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
      change {MyHiFi.Cache.Attachment.Changes.DetachRecord, type: "show"}
    end

    read :subscriptions do
      description "List the shows that a person subscribed to."

      filter expr(subscribed? == true)
      prepare build(sort: [title: :asc])
    end

    create :upsert_from_feed do
      description """
      Write a show from its feed.

      `last_fetched_at` and `last_error` say that this read succeeded, so a page can
      show a feed that stopped working.

      It leaves `subscribed?` and `index_id` alone. The first belongs to the person,
      and the second belongs to the index.
      """

      upsert? true
      upsert_identity :feed_url

      accept [:feed_url, :title, :author, :description, :artwork_url]

      change set_attribute(:last_fetched_at, &DateTime.utc_now/0)
      change set_attribute(:last_error, nil)
    end

    create :upsert_from_index do
      description """
      Write a show from the Podcast Index.

      A row that already exists takes the identifier of the index and nothing else,
      because the publisher owns the title and the description. A show that no feed
      read yet takes each field, so a search shows a title before the device reads
      one feed.
      """

      upsert? true
      upsert_identity :feed_url
      upsert_fields [:index_id]

      accept [:feed_url, :index_id, :title, :author, :description, :artwork_url]
    end

    update :subscribe do
      description "Subscribe to a show. The refresh job then reads its feed."
      change set_attribute(:subscribed?, true)
    end

    update :unsubscribe do
      description """
      Remove the subscription.

      The episodes stay, and so does the position inside each one. A person who
      subscribes again finds their place.
      """

      change set_attribute(:subscribed?, false)
    end

    action :refresh_all, :map do
      description """
      Read the feed of each subscribed show, and remove what no person wants.

      A schedule runs this each six hours. See `MyHiFi.Podcast.Show.RefreshAll`.
      """

      run MyHiFi.Podcast.Show.RefreshAll
    end

    update :record_error do
      description """
      Note that a read of the feed failed.

      `last_fetched_at` stays as it was, so a page can say how old the episodes are
      and why there are no newer ones.
      """

      accept [:last_error]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :feed_url, :string do
      description "The address of the RSS feed. It identifies the show."
      allow_nil? false
      public? true
      constraints min_length: 1
    end

    attribute :index_id, :integer do
      description """
      The feed identifier of the Podcast Index. It is absent for a show that a
      person named by its address, and for a show that the index does not hold.
      """

      public? true
    end

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints min_length: 1
    end

    attribute :author, :string do
      description "From `itunes:author` of the channel."
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :artwork_url, :string do
      description "The cover of the show. The artwork cache holds a copy."
      public? true
    end

    attribute :subscribed?, :boolean do
      description "A person subscribed to this show. The refresh job reads these alone."
      source :subscribed
      allow_nil? false
      default false
      public? true
    end

    attribute :last_fetched_at, :utc_datetime_usec do
      description "When a read of the feed last succeeded."
      public? true
    end

    attribute :last_error, :string do
      description "Why the last read of the feed failed. It is absent after a read that succeeds."
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :episodes, MyHiFi.Podcast.Episode do
      public? true
    end

    # The cache holds no column that names this resource, so the filter is what makes
    # the join belong to a show. See `MyHiFi.Cache.Attachment`.
    has_many :cache_attachments, MyHiFi.Cache.Attachment do
      destination_attribute :record_id
      filter expr(record_type == "show")
      public? true
    end

    many_to_many :cached_files, MyHiFi.Cache.Entry do
      through MyHiFi.Cache.Attachment
      source_attribute_on_join_resource :record_id
      destination_attribute_on_join_resource :entry_id
      join_relationship :cache_attachments
      public? true
    end
  end

  identities do
    identity :feed_url, [:feed_url] do
      description "One row for each feed, so the index and a feed read cannot make two."
    end
  end
end
