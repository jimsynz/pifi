defmodule MyHiFi.Playback.Item do
  @moduledoc """
  One thing that a person plays, and one thing that holds others.

  Every source writes items, and nothing else in the firmware holds a list of media.
  A station, an episode and a show are all items, so a user interface reads one
  resource and it needs no knowledge of any source.

  `kind` says which of the two an item is. A `:track` plays, and a `:container` holds
  others through `parent_id`. A show is a container, and its episodes name it.

  `source` holds the name of the source in an address, and not the module. A module
  name is an atom, and a build that removes a source would then fail to read every
  row of this table. `MyHiFi.Source.from_slug/1` reads the name and reports one that
  this firmware no longer holds.

  ## Two meanings of the word container

  `kind` names a container of the browse tree. `container_format` names what holds
  the audio, which is the `container` field of `MyHiFi.Source.playable`. The two are
  different things, so they have different names here.

  ## The picture

  `artwork_url` is the address, and `cached_files` is what the device holds on the
  card. An item with no address of its own uses the address of its parent, which the
  `artwork` calculation gives. A publisher writes artwork for 70% of the episodes of
  the measurement, and the cover of the show serves the rest.
  """

  use Ash.Resource,
    otp_app: :my_hi_fi,
    domain: MyHiFi.Playback,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "playback_items"
    repo MyHiFi.Repo

    # A container that goes takes what it holds with it. A show that no person wants
    # removes its episodes, which is what the podcast source does by hand today.
    references do
      reference :parent, on_delete: :delete
    end

    # `child_count` counts this column, and it reads no other one. Without the index
    # SQLite reads the whole table for each row of a page.
    custom_indexes do
      index [:parent_id]
    end
  end

  actions do
    default_accept []

    read :read do
      primary? true

      description "Every item."

      # A person moves through a list with a knob, and a page shows part of one. A
      # keyset also holds the place of the track that plays. See `MyHiFi.Player.Queue`.
      pagination keyset?: true, required?: false
    end

    read :by_parent do
      description "List what one container holds."

      argument :parent_id, :uuid, allow_nil?: false

      filter expr(parent_id == ^arg(:parent_id))
      pagination keyset?: true, required?: false
    end

    read :by_source do
      description "List the items of one source."

      argument :source, :string, allow_nil?: false

      filter expr(source == ^arg(:source))
      pagination keyset?: true, required?: false
    end

    read :favourites do
      description "List the items that a person marked."

      filter expr(favourite? == true)
      prepare build(sort: [title: :asc])
      pagination keyset?: true, required?: false
    end

    create :upsert do
      description """
      Write an item from its source.

      `source` and `source_ref` identify it, so a second read of the same service
      updates the row that the first one wrote.

      It leaves `favourite?`, `position_ms`, `position_bytes`, `played?` and
      `last_played_at` alone. Those belong to the person, and a service knows nothing
      of them.
      """

      upsert? true
      upsert_identity :source_ref

      accept [
        :source,
        :source_ref,
        :kind,
        :parent_id,
        :title,
        :subtitle,
        :description,
        :artwork_url,
        :duration_ms,
        :keeps_place?,
        :rank,
        :published_at,
        :url,
        :transport,
        :container_format,
        :format,
        :live?
      ]
    end

    update :set_favourite do
      description "Mark this item."
      change set_attribute(:favourite?, true)
    end

    update :clear_favourite do
      description "Remove the mark from this item."
      change set_attribute(:favourite?, false)
    end

    update :store_position do
      description """
      Keep where a person stopped, for an item that keeps its place.

      `position_bytes` is the byte of the file that the time names, and a stream that
      reads no file leaves it absent. See `MyHiFi.Player.FileSource`.

      An item that keeps no place takes nothing from this, and it reports no error: the
      player tells every item where a person stopped, and a song is not a fault. See
      `MyHiFi.Playback.Item.Changes.KeepPlaceOnly`.
      """

      accept [:position_ms, :position_bytes]

      change MyHiFi.Playback.Item.Changes.KeepPlaceOnly
    end

    update :mark_played do
      description "The item reached its end, so the place in it goes."

      change set_attribute(:played?, true)
      change set_attribute(:position_ms, 0)
      change set_attribute(:position_bytes, nil)
      change set_attribute(:last_played_at, &DateTime.utc_now/0)
    end

    destroy :destroy do
      primary? true

      # The change reads and writes another table, so this destroy is not one
      # statement. A cache row of a record that is going is worth that.
      require_atomic? false

      # The join of the cache holds no key to this record, because no column of the
      # cache names a resource. This host therefore removes its own rows. It removes
      # no entry: one picture serves many records, and the eviction reclaims a file
      # that nothing names any more. See `MyHiFi.Cache.Attachment`.
      change {MyHiFi.Cache.Attachment.Changes.DetachRecord, type: "item"}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :source, :string do
      description "The name of the source in an address, such as `internet-radio`."
      allow_nil? false
      public? true
    end

    attribute :source_ref, :string do
      description "What the source calls this item. It identifies the item there."
      allow_nil? false
      public? true
    end

    attribute :kind, :atom do
      description "`:track` plays, and `:container` holds other items."
      constraints one_of: [:track, :container]
      allow_nil? false
      default :track
      public? true
    end

    attribute :title, :string do
      description "What a person reads first."
      allow_nil? false
      public? true
    end

    attribute :subtitle, :string do
      description "One line under the title, such as the date and the length."
      public? true
    end

    attribute :description, :string do
      description "What the publisher says about it. This is text, and nothing filters on it."
      public? true
    end

    attribute :artwork_url, :string do
      description "The address of the picture. `MyHiFi.Artwork` reads it and the cache holds it."
      public? true
    end

    attribute :duration_ms, :integer do
      description "How long it plays. A stream with no end holds none."
      public? true
    end

    attribute :rank, :integer do
      description """
      What the service says about how popular this item is. A bigger number comes
      first.

      This is a column and not a facet, because a list sorts on it and no data layer
      sorts on a facet. Internet radio writes the click count of Radio Browser here.
      """

      allow_nil? false
      default 0
      public? true
    end

    attribute :published_at, :utc_datetime_usec do
      description """
      When the publisher gave it out.

      This is a column and not a facet, because it differs for each item. See
      `MyHiFi.Playback.Facet`.
      """

      public? true
    end

    attribute :url, :string do
      description "Where the audio is. A container holds none."
      public? true
    end

    attribute :transport, :atom do
      description "How the bytes arrive. See `MyHiFi.Source.playable`."
      constraints one_of: [:http, :hls, :download]
      public? true
    end

    attribute :container_format, :atom do
      description "What holds the audio. This is not `kind`."
      constraints one_of: [:none, :mpeg_ts, :ogg]
      default :none
      public? true
    end

    attribute :format, :atom do
      description "The codec."
      constraints one_of: [:mp3, :aac, :flac, :vorbis, :opus, :speex, :unknown]
      public? true
    end

    attribute :live?, :boolean do
      description "A stream with no end, such as a radio station."
      source :live
      allow_nil? false
      default false
      public? true
    end

    attribute :favourite?, :boolean do
      description "A person marked it. A person subscribes to a show this way."
      source :favourite
      allow_nil? false
      default false
      public? true
    end

    attribute :keeps_place?, :boolean do
      description """
      A person goes on from where they stopped, on a later day.

      An episode of a podcast and a chapter of an audiobook keep their place. A song
      does not: a person who stops half way through one does not want the second half
      of it tomorrow. A live stream holds no place at all.

      This belongs to the item and not to the source, because one library holds both
      an album and an audiobook.
      """

      source :keeps_place
      allow_nil? false
      default false
      public? true
    end

    attribute :position_ms, :integer do
      description "Where a person stopped."
      allow_nil? false
      default 0
      public? true
    end

    attribute :position_bytes, :integer do
      description "The byte of the file that `position_ms` names."
      public? true
    end

    attribute :played?, :boolean do
      description "It reached its end."
      source :played
      allow_nil? false
      default false
      public? true
    end

    attribute :last_played_at, :utc_datetime_usec do
      description "When a person last played it."
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :parent, __MODULE__ do
      description "The container that holds this item."
      public? true
    end

    has_many :children, __MODULE__ do
      destination_attribute :parent_id
      public? true
    end

    has_many :item_facets, MyHiFi.Playback.ItemFacet do
      public? true
    end

    many_to_many :facets, MyHiFi.Playback.Facet do
      through MyHiFi.Playback.ItemFacet
      source_attribute_on_join_resource :item_id
      destination_attribute_on_join_resource :facet_id
      join_relationship :item_facets
      public? true
    end

    # The cache holds no column that names this resource, so the filter is what makes
    # the join belong to an item. See `MyHiFi.Cache.Attachment`.
    has_many :cache_attachments, MyHiFi.Cache.Attachment do
      destination_attribute :record_id
      filter expr(record_type == "item")
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

  calculations do
    calculate :child_count,
              :integer,
              {MyHiFi.Playback.GroupedCount, table: "playback_items", column: "parent_id"} do
      description """
      How many items name this one as their container.

      A show says how many episodes it holds. It is 0 for a track, which holds nothing.
      """
    end

    calculate :artwork, :string, expr(artwork_url || parent.artwork_url) do
      description """
      The address of the picture of this item, or of the container that holds it.

      One rule serves every source. A publisher writes artwork for 70% of the
      episodes of the measurement, and the cover of the show serves the rest.
      """

      public? true
    end
  end

  identities do
    identity :source_ref, [:source, :source_ref] do
      description "One row for each item of each source."
    end
  end
end
