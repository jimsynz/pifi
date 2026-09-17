defmodule PiFi.Podcast.Show do
  @moduledoc """
  One podcast.

  A show arrives in two ways. The Podcast Index gives one that a person found by a
  search, and `PiFi.Podcast.Feed` gives one that a person named by its address.
  `feed_url` identifies the show in both, so the two never make a second row for
  the same podcast.

  A subscription is a mark on the item of the show, because that is what a person did.
  The refresh job reads the subscribed shows alone, so a search costs the device
  nothing later.
  """

  alias PiFi.Podcast.Trending

  use Ash.Resource,
    otp_app: :pifi,
    domain: PiFi.Podcast,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshOban]

  # A feed changes when a publisher writes an episode, and no publisher writes one
  # each minute. An hour is short enough that a person who opens a show twice in a day
  # sees the new episode, and long enough that moving through the tree reads no feed
  # twice.
  @stale_after_hours 1

  sqlite do
    table "podcast_shows"
    repo PiFi.Repo
  end

  oban do
    triggers do
      # A person opening a show whose local copy is old must not wait for the
      # network, so the read happens here. `scheduler_cron false` means that nothing
      # looks for work: `AshOban.run_trigger/2` is the one way that this job arrives.
      #
      # Two opens of one show ask twice, and `where` is what keeps the reads to one.
      # The job reads the show again, and a copy that the first job made new cancels
      # the second.
      trigger :refresh do
        action :refresh
        where expr(stale?)
        scheduler_cron false
        worker_module_name PiFi.Podcast.Show.Workers.Refresh
        queue :default
        max_attempts 1
      end
    end

    scheduled_actions do
      # A person browses Trending, and that must not wait for the network. The list of
      # the index moves slowly, so one read each day is enough.
      schedule :read_trending, "0 5 * * *" do
        action :read_trending
        worker_module_name PiFi.Podcast.Show.Workers.ReadTrending
        queue :default
        max_attempts 3
      end

      # A publisher writes an episode, and no publisher writes one each hour. Four
      # reads of each feed in a day is often enough for a person who listens each
      # day, and it reads the subscribed shows only.
      schedule :refresh_all, "0 */6 * * *" do
        action :refresh_all
        worker_module_name PiFi.Podcast.Show.Workers.RefreshAll
        queue :default
        max_attempts 3
      end
    end
  end

  actions do
    default_accept []

    # A search writes a show that a person may never open again, so something must
    # be able to remove one.
    defaults [:read]

    destroy :destroy do
      primary? true

      # The change reads and writes another table, so this destroy is not one
      # statement. A cache row of a record that is going is worth that.
      require_atomic? false

      # The join of the cache carries no key to this record, because no column of the
      # cache names a resource. This host therefore removes its own rows. It removes
      # no entry: one picture serves many records, and the eviction reclaims a file
      # that nothing names any more. See `PiFi.Cache.Attachment`.
      change {PiFi.Cache.Attachment.Changes.DetachRecord, type: "show"}
    end

    read :subscriptions do
      description """
      List the shows that a person subscribed to.

      The mark is on the item and not here, because a subscription is what a person did
      and `PiFi.Playback.Item` keeps all of that. This read joins to it, so one row
      carries the answer.
      """

      filter expr(item.favourite? == true)
    end

    create :upsert_from_feed do
      description """
      Write a show from its feed.

      `last_fetched_at` and `last_error` say that this read succeeded, so a page can
      show a feed that stopped working.

      It leaves `index_id` alone, because that belongs to the index.
      """

      upsert? true
      upsert_identity :feed_url

      accept [:feed_url]

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

      accept [:feed_url, :index_id]
    end

    update :set_item do
      description "Name the item of the catalogue for this show."
      accept [:item_id]
    end

    update :refresh do
      description """
      Read the feed of this show and write what it gives.

      The action changes no attribute of its own. `PiFi.Podcast.Refresh` writes the
      show and the episodes through their own actions, so a trigger has one record to
      name and one job to run.
      """

      require_atomic? false

      change PiFi.Podcast.Show.Changes.Refresh
    end

    action :read_trending, :integer do
      description """
      Read the popular shows of the Podcast Index, and mark them.

      See `PiFi.Podcast.Trending`. It returns the number of shows that it marked, and
      0 for a device with no key of the index.
      """

      run fn _input, _context ->
        case Trending.run() do
          {:ok, count} -> {:ok, count}
          {:error, _reason} -> {:ok, 0}
        end
      end
    end

    action :refresh_all, :map do
      description """
      Read the feed of each subscribed show, and remove what no person wants.

      A schedule runs this each six hours. See `PiFi.Podcast.Show.RefreshAll`.
      """

      run PiFi.Podcast.Show.RefreshAll
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
    belongs_to :item, PiFi.Playback.Item do
      description """
      The container of the catalogue that a person browses.

      A show carries the address of the feed and what a read of it gave. Everything that
      a person sees and does is on the item.
      """

      public? true
    end

    # The cache has no column that names this resource, so the filter is what makes
    # the join belong to a show. See `PiFi.Cache.Attachment`.
    has_many :cache_attachments, PiFi.Cache.Attachment do
      destination_attribute :record_id
      filter expr(record_type == "show")
      public? true
    end

    many_to_many :cached_files, PiFi.Cache.Entry do
      through PiFi.Cache.Attachment
      source_attribute_on_join_resource :record_id
      destination_attribute_on_join_resource :entry_id
      join_relationship :cache_attachments
      public? true
    end
  end

  calculations do
    # `ago/2` gives no answer on AshSqlite. A filter on it matches no row, and a
    # calculation of it gives `nil` for a row that carries a date. `datetime_add/3`
    # gives the right answer in both.
    calculate :stale?,
              :boolean,
              expr(
                is_nil(last_fetched_at) or
                  last_fetched_at < datetime_add(now(), ^(-1 * @stale_after_hours), :hour)
              ) do
      description """
      The local copy of the feed is old, so a device reads it again.

      `PiFi.Source.Podcasts` asks for a read when a person opens the show, and the
      `refresh` trigger asks again when the job runs. One rule answers both.
      """

      public? true
    end
  end

  identities do
    identity :feed_url, [:feed_url] do
      description "One row for each feed, so the index and a feed read cannot make two."
    end
  end
end
