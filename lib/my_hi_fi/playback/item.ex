defmodule MyHiFi.Playback.Item do
  @moduledoc """
  One thing that a person plays, or one thing that contains others.

  Every source writes items, and nothing else in the firmware keeps a list of media.
  A station, an episode and a show are all items, so a user interface reads one
  resource and it needs no knowledge of any source.

  `kind` says which of the two an item is. A `:track` plays, and a `:container`
  contains others through `parent_id`. A show is a container, and each of its episodes
  points to it.

  `source` is the name of the source in an address, and not the module. A module name
  is an atom, and a build that removed a source would then fail to read every row of
  this table. `MyHiFi.Source.from_slug/1` reads the name, and it reports a source that
  this firmware no longer has.

  ## Two meanings of the word container

  `kind` names a container of the browse tree. `container_format` names what carries
  the audio, which is the `container` field of `MyHiFi.Source.playable`. The two are
  different things, so they have different names here.

  ## The picture

  `artwork_url` is the address, and `cached_files` is what the device keeps on the
  card. An item with no address of its own uses the address of its parent, and the
  `artwork` calculation returns that. A publisher writes artwork for 70% of the episodes of
  the measurement, and the cover of the show serves the rest.

  ## The audio of a favourite

  A mark reads the audio on to the card, so a person hears what they marked with no
  wait and hears it when the service is off. `caches_audio?` says which items that
  covers, and it names no source: `transport` and `keeps_place?` are the two facts
  that decide. See `MyHiFi.Playback.FavouriteAudio`.
  """

  alias MyHiFi.Playback.FavouriteAudio

  use Ash.Resource,
    otp_app: :my_hi_fi,
    domain: MyHiFi.Playback,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshOban]

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

    # **The order is part of the index, and that is the point.** Every branch of a
    # source reads the items of one source of one kind, in the order of the title.
    # With an index of the source alone, SQLite reads each row of that source, keeps
    # the ones that match, and then builds a temporary tree to put 4377 albums in
    # order, for each page of 100 that a person reads.
    #
    # A measurement on a library of 53,105 items showed that: `SEARCH USING INDEX
    # playback_items_source_ref_index (source=?)` and `USE TEMP B-TREE FOR ORDER BY`,
    # 612 ms, and 20 MB for one page. The device holds 363.9 MB and serves each page
    # from one of ten connections, so each one held a part of the table and the board
    # ran out of memory. With this index the same plan reads `SEARCH USING INDEX
    # playback_items_source_kind_title_nocase_index (source=? AND kind=?)`, it sorts
    # nothing, and it stops at the hundredth row.
    #
    # **`custom_indexes` cannot write these**, because each one holds an expression and
    # that section takes a name alone.
    #
    # ## Each index names the expression that Ash writes, and it must
    #
    # **`kind` is `Ash.Type.Atom`, and Ash compares such a column as
    # `CAST(kind AS TEXT) = CAST(? AS TEXT)`.** A cast of a column is an expression, and
    # SQLite cannot use an index of the column for one. An index of
    # `(source, kind, title COLLATE NOCASE)` therefore served no read of this table at
    # all: the planner took `playback_items_source_ref_index` for `source=?` alone and
    # built a temporary tree to order every row of that source.
    #
    # A measurement of the four branches of each source on a board on 2026-09-14 gave
    # `SEARCH p0 USING INDEX playback_items_source_ref_index (source=?)` and
    # `USE TEMP B-TREE FOR ORDER BY` for every one of them:
    #
    #     jellyfin / Artists          1810 ms
    #     jellyfin / Albums           1090 ms
    #     jellyfin / Recently added   1012 ms
    #     jellyfin / Favourites        953 ms
    #     plex / Recently added        649 ms
    #     plex / Albums                369 ms
    #
    # A page reads a count beside the rows, so a person waited twice those numbers. The
    # index of the cast gives `SEARCH p0 USING INDEX
    # playback_items_source_kind_title_nocase_index (source=? AND <expr>=?)` and
    # `USE TEMP B-TREE FOR LAST TERM OF ORDER BY`, and five reads of the Plex branch of
    # 4360 albums took 7 to 17 ms where the same five took 317 to 335 ms without it.
    #
    # The last term of that order is `id`, which Ash adds so that a page of a keyset is
    # stable. It orders the rows of one title, and there are few of those.
    #
    # `favourite?` is a boolean, and Ash writes `CAST(favourite AS INTEGER)` for the
    # same reason. `added_at` is a date, and it needs no cast, so the branch that reads
    # the newest records first needs the date and not the title.
    custom_statements do
      statement :source_kind_title_nocase do
        up """
        CREATE INDEX playback_items_source_kind_title_nocase_index
        ON playback_items (source, CAST(kind AS TEXT), title COLLATE NOCASE)
        """

        down "DROP INDEX playback_items_source_kind_title_nocase_index"
      end

      statement :source_kind_added_at do
        up """
        CREATE INDEX playback_items_source_kind_added_at_index
        ON playback_items (source, CAST(kind AS TEXT), added_at)
        """

        down "DROP INDEX playback_items_source_kind_added_at_index"
      end

      # The history reads every source together, so this index names no source. It
      # holds the rows that carry a date, because `:history` reads those alone, and a
      # library of 137,575 rows holds a few hundred of them.
      statement :last_started_at do
        up """
        CREATE INDEX playback_items_last_started_at_index
        ON playback_items (last_started_at)
        WHERE last_started_at IS NOT NULL
        """

        down "DROP INDEX playback_items_last_started_at_index"
      end

      statement :source_favourite_title_nocase do
        up """
        CREATE INDEX playback_items_source_favourite_title_nocase_index
        ON playback_items (source, CAST(favourite AS INTEGER), title COLLATE NOCASE)
        """

        down "DROP INDEX playback_items_source_favourite_title_nocase_index"
      end
    end
  end

  oban do
    triggers do
      # A person presses one control, and the control must answer at once, so the
      # read of the audio happens here. `scheduler_cron false` means that nothing
      # looks for work: `AshOban.run_trigger/2` is the one way that this job arrives,
      # and `MyHiFi.Jellyfin.Sync.Favourites` is the other caller of it.
      #
      # Two presses ask twice, and `where` is what holds the reads to one. Oban
      # cannot make the job unique, because AshOban puts `tenant: nil` in the
      # arguments and its SQLite engine compares them as JSON. The job reads the item
      # again instead, and an item that lost its mark cancels the job.
      trigger :cache_audio do
        action :cache_audio
        where expr(caches_audio?)
        scheduler_cron false
        worker_module_name MyHiFi.Playback.Item.Workers.CacheAudio
        queue :default
        max_attempts 1
      end
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
      prepare build(sort: [sorted_title: :asc])
      pagination keyset?: true, required?: false
    end

    read :marked_for_audio do
      description """
      The items of one source whose audio this device keeps, because a person marked
      them.

      It returns the item that a person marked. It does not return the tracks under
      that item, and one job takes one of these and reads everything under it.

      **The newest mark comes first.** A card that fills stops the run, so the order
      decides what the device keeps: what a person marked a moment ago, and not what
      they marked a year ago. An item that an older firmware marked carries no time,
      and it comes last. See `MyHiFi.Playback.FavouriteAudio`.
      """

      argument :source, :string, allow_nil?: false

      filter expr(source == ^arg(:source) and caches_audio?)
      prepare build(sort: [favourited_at: :desc])
    end

    read :by_ids do
      description """
      The items with these identifiers, in no particular order.

      **The play queue reads this.** A queue row lives in ETS and an item lives in
      SQLite, so Ash cannot join the two, and reading one item per row would mean one
      query per row. See `MyHiFi.Playback.Queue`.

      The caller keeps the order, because a queue is ordered by its rows and not by its
      items.
      """

      argument :ids, {:array, :uuid}, allow_nil?: false

      filter expr(id in ^arg(:ids))
    end

    read :holding_audio do
      description """
      Every item whose audio this device keeps on the card.

      The storage report reads it, so a person sees which source uses the room. It
      returns the item that owns a file, and never the container above it, because the
      card keeps a track and never an album.

      **The size is a field of the cache entry and not of the item**, so this loads
      `audio_file`. `byte_size` of an item is what a service said the file would be,
      and the two differ.
      """

      filter expr(not is_nil(audio_file.id))
      prepare build(load: [:audio_file])
    end

    read :history do
      description """
      Every item that this device has played, the most recent first.

      A person who heard something and wants it again reads this. It holds one row for
      each item and not one for each play, because a person who played an album twelve
      times wants to find the album and not twelve rows of it. `last_started_at` is
      therefore the last time and not a list of times.
      """

      filter expr(not is_nil(last_started_at))

      prepare build(sort: [last_started_at: :desc])
    end

    update :mark_started do
      description """
      Say that this device began to make a sound of this item.

      `MyHiFi.Player` runs this when the pipeline says that the sound began, and not
      when a person presses a control: a stream that never arrives is not something
      that they heard.

      **This writes one row for each track that plays**, and a track is minutes long, so
      the cost to the card is small. A live stream that the network broke restarts, and
      each restart writes this again, which `MyHiFi.Player` bounds to five.
      """

      accept []

      change set_attribute(:last_started_at, &DateTime.utc_now/0)
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
        :source_key,
        :kind,
        :parent_id,
        :title,
        :subtitle,
        :description,
        :artwork_url,
        :duration_ms,
        :byte_size,
        :keeps_place?,
        :rank,
        :published_at,
        :release_year,
        :added_at,
        :number,
        :disc,
        :url,
        :transport,
        :container_format,
        :format,
        :live?,
        :last_seen_at
      ]
    end

    update :set_favourite do
      description """
      Mark this item.

      A mark also asks for the audio of what it covers, so a person who marks an
      album hears it with no wait and hears it when the service is off. The ask puts
      a job in the queue and it reaches no network, because a person pressed a
      control and the control must answer at once. See
      `MyHiFi.Playback.FavouriteAudio`.
      """

      # The hook puts a job in the queue, and no statement of SQLite can do that.
      require_atomic? false

      change set_attribute(:favourite?, true)
      change set_attribute(:favourited_at, &DateTime.utc_now/0)

      change after_action(fn _changeset, item, _context ->
               FavouriteAudio.ask(item)

               {:ok, item}
             end)
    end

    update :clear_favourite do
      description """
      Remove the mark from this item.

      The audio that the mark read stays on the card, and it becomes an ordinary
      entry of the cache that an eviction may take. A person who changes their mind
      twice in a minute therefore reads the album one time. See
      `MyHiFi.Playback.FavouriteAudio`.
      """

      require_atomic? false

      change set_attribute(:favourite?, false)
      change set_attribute(:favourited_at, nil)

      change after_action(fn _changeset, item, _context ->
               FavouriteAudio.release(item)

               {:ok, item}
             end)
    end

    update :cache_audio do
      description """
      Read the audio of this item on to the card.

      The `:cache_audio` trigger runs this. It changes no attribute of its own:
      `MyHiFi.Playback.FavouriteAudio` reads the tracks and writes them to the cache.
      """

      require_atomic? false

      change MyHiFi.Playback.Item.Changes.CacheAudio
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
      description """
      The item is played, so the place in it goes.

      `MyHiFi.Player` runs this when a track reaches its end, and a person runs it by
      hand for an episode that they are done with. Both mean the same thing, so both
      take the same step: the audio of the track becomes an ordinary entry of the
      cache, which an eviction may take.
      """

      # The change reads the cache, and no statement of SQLite can do that.
      require_atomic? false

      change set_attribute(:played?, true)
      change set_attribute(:position_ms, 0)
      change set_attribute(:position_bytes, nil)
      change set_attribute(:last_played_at, &DateTime.utc_now/0)
      change MyHiFi.Playback.Item.Changes.ReleaseAudio
    end

    update :clear_played do
      description """
      Take the mark off an item that a person wants to hear again.

      The place is already gone, because `:mark_played` dropped it, so the item begins
      at the start. The file of a track that keeps its place comes back at the next
      read of the source: `MyHiFi.Playback.FavouriteAudio` holds the newest few
      episodes that a person has not played, and this item is one of them again.
      """

      change set_attribute(:played?, false)
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

      # A track that goes takes its audio with it. `MyHiFi.Player.Download` writes the
      # file with `keep?`, and `:mark_played` and `MyHiFi.Player.release_file/1` are the
      # two things that take that mark off. A row that goes reaches neither, so the file
      # would hold the card for ever and nothing could ever name it again.
      change MyHiFi.Playback.Item.Changes.ReleaseAudio
    end

    action :remove_cache, :integer do
      description """
      Remove what the cache holds for one source, and keep the rows of it. It returns
      how many entries went.

      A person who takes a source out of use asks for the room of it back, and the
      eviction gives them that only when the card runs short. A mark holds nothing
      against this. See `MyHiFi.Playback.Item.RemoveCache`.
      """

      argument :source, :string, allow_nil?: false

      run MyHiFi.Playback.Item.RemoveCache
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

    attribute :source_key, :string do
      description """
      What a source needs to reach the audio, beside the address of the service.

      **This is not `url`, and it is not `source_ref`.** `url` is the whole address,
      and a source that keeps one there needs nothing here. `source_ref` identifies
      the item, and a service that names the audio by something else writes that
      thing here.

      `MyHiFi.Source.Plex` is the one source that uses it. Plex serves the file as
      it is, and it names the path of that file in the answer that lists a track. The
      address of a play is that path with the access token of the moment behind it, so
      the path keeps and the address does not. A track without this column would cost
      a read of the server for each play and for each mark that reads on to the card.

      A source that needs none leaves it empty.
      """

      public? true
    end

    attribute :kind, :atom do
      description "`:track` plays, and `:container` contains other items."
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
      description "The address of the picture. `MyHiFi.Artwork` reads that address, and the cache keeps the file."
      public? true
    end

    attribute :duration_ms, :integer do
      description "How long it plays. A stream with no end has none."
      public? true
    end

    attribute :byte_size, :integer do
      description """
      How many bytes the audio takes. A container and a live stream have none.

      `MyHiFi.Playback.FavouriteAudio` reads this before it asks for a track, so it
      can see whether the cache has room for one. That check must reach no service,
      because a device with no network still has to decide. A source that cannot say
      leaves it absent, and the check estimates the size from `duration_ms` instead.
      """

      public? true
    end

    attribute :number, :integer do
      description """
      The place of this item inside the container that it belongs to.

      A track carries its track number, and an episode carries the number that the
      publisher gave it. **It is absent for an item that has no such place**, and a
      feed that names none gets none: `MyHiFi.Podcast.Feed.Parser` keeps 200 episodes
      of a feed that may hold 2955, so the place in the list would print a confident
      and wrong episode number.

      A list sorts on this before it sorts on anything else, and SQLite reads an absent
      value as the smallest one, so a container whose items hold none falls through to
      the order that its source names. See `c:MyHiFi.Source.listing/1`.
      """

      public? true
    end

    attribute :disc, :integer do
      description """
      Which disc of a set holds this track.

      An album of one disc leaves this absent, and a set of two names 1 and 2. A row of
      such a set reads `2-12`, because track 1 of disc 2 comes after track 12 of disc 1
      and the number alone cannot say that.
      """

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

    attribute :release_year, :integer do
      description "The release year of an album."
      public? true
    end

    attribute :added_at, :utc_datetime_usec do
      description """
      When the service first held this item.

      **It is the date of the service and not of this device.** `inserted_at` says
      when this device first read the row, and a person who writes a new card gets
      that date for every album of a library at once. A list of what a person added
      last month must survive that, so the number comes from the service. Jellyfin
      names it `DateCreated`. See `MyHiFi.Jellyfin.Server.album/2`.

      It is nil for a source that names no such date, and for a row that a firmware
      before this column wrote.
      """

      public? true
    end

    attribute :url, :string do
      description "Where the audio is. A container has none."
      public? true
    end

    attribute :transport, :atom do
      description "How the bytes arrive. See `MyHiFi.Source.playable`."
      constraints one_of: [:http, :hls, :download]
      public? true
    end

    attribute :container_format, :atom do
      description "What carries the audio. This is not `kind`."
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

    attribute :favourited_at, :utc_datetime_usec do
      description """
      When a person put the mark on. It is absent for an item with no mark.

      **`updated_at` cannot answer this.** A sync writes every row that a service
      owns, so that time says when the device last read the service and not when a
      person chose the item.

      `MyHiFi.Playback.FavouriteAudio` reads the marked items newest first, and this
      is the order. A card that fills therefore holds what a person marked most
      recently, and the run settles instead of writing the card for ever.
      """

      public? true
    end

    attribute :keeps_place?, :boolean do
      description """
      A person goes on from where they stopped, on a later day.

      An episode of a podcast and a chapter of an audiobook keep their place. A song
      does not: a person who stops half way through one does not want the second half
      of it tomorrow. A live stream has no place at all.

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
      description "When the item last reached its end, or when a person marked it played."
      public? true
    end

    attribute :last_started_at, :utc_datetime_usec do
      description """
      When this device last began to make a sound of this item.

      **This is not `last_played_at`.** That one says that a person is done with the
      item, and it carries the podcast rule: an episode that reached its end is one to
      leave behind. This one says that they heard it, and it is what the history reads.
      A station never reaches an end, so it never held the other column, and a station
      is the very thing that a person wants to find again.

      It is nil for an item that this device has not played.
      """

      public? true
    end

    attribute :last_seen_at, :utc_datetime_usec do
      description """
      When a read of the service last saw this item.

      A source that reads a whole library writes this on each row that it sees. What
      the read did not see is a thing that the service no longer holds, and the read
      removes it. See `MyHiFi.Jellyfin.Sync.Library`.

      It is nil for a row that a source wrote before this column, and for a source
      that reads no whole library. A remover therefore names its own source, and it
      never reads a row of another one.
      """

      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :parent, __MODULE__ do
      description "The container that this item belongs to."
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

    # **The audio of a track is a cache entry whose key is the identifier of the item**,
    # and `MyHiFi.Player.Download` writes it in the `download` namespace. The cache
    # holds no column that names this resource, so the key and the namespace are what
    # make the join.
    has_one :audio_file, MyHiFi.Cache.Entry do
      source_attribute :id
      destination_attribute :entry_key
      filter expr(namespace == "download")

      # **The key of a cache entry is text, and the identifier of an item is a UUID.**
      # A caller invents a key, so that column takes any string: the artwork of a
      # station is keyed by the hash of an address. Ash reports the two types as
      # possibly incompatible and the join is correct, because the audio of an item is
      # keyed by the identifier of that item and by nothing else.
      validate_destination_attribute? false

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

      A show says how many episodes it contains. It is 0 for a track, which contains none.
      """
    end

    calculate :caches_audio?,
              :boolean,
              expr(
                favourite? == true and
                  ((kind == :track and transport == :download and keeps_place? == false) or
                     exists(children, transport == :download) or
                     exists(children.children, transport == :download))
              ) do
      description """
      A person marked this item, and this device holds the audio of what it covers.

      **It names no source, and it must not.** `transport` says that the audio is a
      file that this device reads, so a station reads nothing at all: a live stream has
      no file to keep.

      **A mark reaches two levels.** A mark on an album reads every track of it, and a
      mark on an artist reads a whole discography, because a person who marks one has
      said what they want the card for and the run stops at the first track that the
      card holds no room for.

      **A container of episodes reads too, and a count is what holds it down.** An
      episode keeps its place, and this said false for a show for that reason, so a
      person who subscribed to a show could not hear it away from the network. A show
      has hundreds of episodes and no podcast reader keeps a whole feed, so
      `c:MyHiFi.Source.hold_limit/0` says how many of the newest a source keeps. A
      track that keeps its place and that a person marked by itself still reads
      nothing, because a person marks the show and not the episode.

      See `MyHiFi.Playback.FavouriteAudio`.
      """
    end

    calculate :place, :integer, expr((disc || 0) * 1000 + number) do
      description """
      The disc and the number of a track as one number, so one column sorts a set.

      **A sort of two columns cannot do this work.** `Cinder.QueryBuilder` unsets the
      sort of a query as soon as a person presses a sort control, and it applies the one
      column that they pressed, so `[disc: :asc, number: :asc]` became `number` alone
      and a set of two discs read 1-01, 2-01, 1-02, 2-02.

      1000 is larger than the track count of any record. An album of one disc carries no
      `disc`, so the number decides, and an item with no number gives nothing at all: SQLite reads an absent value as the smallest, and such an item leads a list
      whose other rows hold numbers.

      `MyHiFiWeb.ItemList.place_text/1` draws the same fact for a person to read, as
      `1-01`.
      """

      public? true
    end

    calculate :sorted_title, Ash.Type.CiString, expr(title) do
      description """
      The title of this item, in the order that a person reads a list in.

      **SQLite compares text byte by byte, so `title` puts every capital letter in
      front of every small one.** A library of albums therefore listed `Wolfmother`
      before `alt-J`, and a person who looked under A found nothing. `Ash.Type.CiString`
      is what removes that: AshSqlite writes `title COLLATE NOCASE` for a term of that
      type, and SQLite then compares the letters and not the bytes.

      **Sort by this and never by `title`.** A sort of the attribute reads the order of
      the bytes, and this is the one column that reads the order of the letters, in the
      way that `place` is the one column that reads the order of a set. The custom
      statement above declares the index that serves it.
      """

      public? true
    end

    calculate :audio_held?, :boolean, expr(not is_nil(audio_file.id)) do
      description """
      This device keeps the audio of this item on the card.

      A person reads it to know what plays with no network, and a list draws it beside
      the title. **It is one query for a page and not one for each row**, because it
      rides along with the read that draws the list, in the way that `child_count`
      does.

      A container gives `false`. The audio of an album is the audio of its tracks, and
      a person opens the album to read which of them the card holds.
      """

      public? true
    end

    calculate :remaining_ms, :integer, expr(duration_ms - position_ms) do
      description """
      How much of this item a person has not heard.

      An episode of a podcast keeps its place, so a person reads how much is left of
      it. `position_ms` allows no nil and it begins at 0, so this is the whole duration
      of an item that no person began.

      **A live stream and an item of an unknown length give nothing.** `duration_ms` is
      absent for both, and SQLite gives nothing for a sum that holds nothing, so a row
      of one draws no time left. See `c:MyHiFi.Source.listing/1`.
      """

      public? true
    end

    calculate :artwork, :string, expr(artwork_url || parent.artwork_url) do
      description """
      The address of the picture of this item, or of the container that it belongs to.

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
