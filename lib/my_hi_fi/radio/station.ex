defmodule MyHiFi.Radio.Station do
  @moduledoc """
  One internet radio station.

  The station list comes from the public Radio Browser service, and an Oban job
  copies a country at a time into this table. Search then works on the local copy,
  and it works without the internet.
  """

  use Ash.Resource,
    otp_app: :my_hi_fi,
    domain: MyHiFi.Radio,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshOban]

  sqlite do
    table "stations"
    repo MyHiFi.Repo
  end

  oban do
    scheduled_actions do
      # A station list changes slowly, and each run asks the service for a whole
      # country. One time each week is often enough, and it is kind to a service
      # that asks nothing for its work.
      schedule :sync_from_remote, "0 4 * * 0" do
        action :sync_from_remote
        worker_module_name MyHiFi.Radio.Station.Workers.SyncFromRemote
        queue :default
        max_attempts 3
      end
    end
  end

  actions do
    default_accept []

    defaults [:read]

    read :search do
      description """
      Find a station by title or by tag.

      The most popular station comes first, because `click_count` says how often a
      person elsewhere chose that station.
      """

      argument :query, :string, allow_nil?: false

      # `contains/2` compiles to `instr`, and `instr` in SQLite matches the case.
      # A person searching for "rnz" would then miss "RNZ National". Both clauses
      # therefore lower each side.
      #
      # `instr` is right and `like` is wrong here. `like` also ignores the case,
      # and it reads `%` and `_` in the text of the person as wildcards.
      filter expr(
               fragment("instr(lower(?), lower(?)) > 0", title, ^arg(:query)) or
                 fragment(
                   "EXISTS (SELECT 1 FROM json_each(?) WHERE instr(lower(value), lower(?)) > 0)",
                   tags,
                   ^arg(:query)
                 )
             )

      prepare build(sort: [click_count: :desc, title: :asc])
    end

    read :favourites do
      description "List the stations that a person marked."

      filter expr(favourite? == true)
      prepare build(sort: [title: :asc])
    end

    create :upsert_from_remote do
      description """
      Write a station from the Radio Browser service.

      The sync job calls this for each station of each country that a person
      chose. `remote_id` identifies the station, so a second run updates the row
      that the first run wrote. It leaves `favourite?` and `last_played_at` alone,
      because those belong to the person and not to the service.
      """

      upsert? true
      upsert_identity :remote_id

      accept [
        :remote_id,
        :title,
        :stream_url,
        :codec,
        :bitrate,
        :hls?,
        :country_code,
        :language,
        :tags,
        :artwork_url,
        :click_count
      ]
    end

    update :set_favourite do
      description "Mark a station."
      change set_attribute(:favourite?, true)
    end

    update :clear_favourite do
      description "Remove the mark from a station."
      change set_attribute(:favourite?, false)
    end

    action :sync_from_remote, :map do
      description """
      Copy the station list of each chosen country into this table.

      A weekly schedule runs this, and the first start of a device runs it once.
      """

      argument :countries, {:array, :string},
        allow_nil?: true,
        description: "The countries to copy. It reads the settings when this is absent."

      run MyHiFi.Radio.Station.SyncFromRemote
    end

    update :record_play do
      description """
      Note that the device played this station.

      Standby mode reads this to start the last station again.
      """

      change atomic_update(:last_played_at, expr(now()))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :remote_id, :string do
      description "The identifier that the Radio Browser service gives. It is absent for a station that a person added."
      public? true
    end

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints min_length: 1
    end

    attribute :stream_url, :string do
      allow_nil? false
      public? true
      constraints min_length: 1
    end

    attribute :codec, :string do
      description "MP3, AAC, AAC+, OGG, or UNKNOWN, as the service reports it."
      public? true
    end

    attribute :bitrate, :integer do
      description "In kilobits each second. It is 0 when the service does not know."
      public? true
    end

    attribute :hls?, :boolean do
      description """
      True for a station that sends HLS, and false for a Shoutcast stream. The
      player chooses the pipeline from this.
      """

      source :hls
      allow_nil? false
      default false
      public? true
    end

    attribute :country_code, :string do
      description "Two letters, such as NZ."
      public? true
    end

    attribute :language, :string do
      public? true
    end

    attribute :tags, {:array, :string} do
      description "The tags of the service, such as news or rock. The search action reads them."
      allow_nil? false
      default []
      public? true
    end

    attribute :artwork_url, :string do
      description "The logo of the station. The artwork cache holds a copy."
      public? true
    end

    attribute :favourite?, :boolean do
      description "A person marked this station. The sync job leaves it alone."
      source :favourite
      allow_nil? false
      default false
      public? true
    end

    attribute :last_played_at, :utc_datetime_usec do
      description "When the device last played this station. The sync job leaves it alone."
      public? true
    end

    attribute :click_count, :integer do
      description """
      How often a person elsewhere chose this station, as the Radio Browser
      service counts it. The search action sorts by it.
      """

      allow_nil? false
      default 0
      public? true
    end

    timestamps()
  end

  identities do
    identity :remote_id, [:remote_id] do
      description "One row for each station of the service, so the sync job updates and does not duplicate."
      nils_distinct? true
    end
  end
end
