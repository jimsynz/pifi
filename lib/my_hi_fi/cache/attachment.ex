defmodule MyHiFi.Cache.Attachment do
  @moduledoc """
  Joins one entry of the cache to one record that uses it.

  A record names the thing that it stands for, and an entry keeps the bytes. Many records
  may name one entry, which is the point: a publisher that uses one cover for a show
  and for each of its 200 episodes gives 201 rows here and **one** file of 1.2 MB.
  A join that put the record on the entry would give 201 files and 240 MB.

  `record_type` and `record_id` name the record, and no column names a resource. The
  cache therefore needs no knowledge of the parts of the firmware that use it, which
  is the whole point of a cache that anything may use. A host declares its own
  relationship and filters for its own type. See `MyHiFi.Podcast.Show`.

  ## What this costs

  A polymorphic join carries no foreign key to the record, so the database cannot refuse
  a row that names a record which is gone. The entry is different: the database enforces
  that key and removes the join rows with the entry.

  **A record that goes therefore leaves its rows behind.** A host that removes itself
  must remove them, because only the host knows its own type. No host does that yet.
  """

  use Ash.Resource,
    otp_app: :my_hi_fi,
    domain: MyHiFi.Cache,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "cache_attachments"
    repo MyHiFi.Repo

    references do
      # An eviction must be able to take a file that records still name. It removes
      # the join rows with it, and each record keeps the address that it came from, so
      # the next read fetches the file again. A key that refused the eviction would
      # let the cache fill with entries that nothing may remove.
      reference :entry, on_delete: :delete
    end
  end

  actions do
    default_accept []

    defaults [:read, :destroy]

    create :attach do
      description """
      Say that one record uses one entry.

      The same record and the same entry give the row that is already there, so a
      caller may say it again without a read first.
      """

      upsert? true
      upsert_identity :entry_record

      accept [:entry_id, :record_type, :record_id]
    end

    read :for_record do
      description "Every entry that one record uses."

      argument :record_type, :string, allow_nil?: false
      argument :record_id, :uuid, allow_nil?: false

      filter expr(record_type == ^arg(:record_type) and record_id == ^arg(:record_id))
    end

    read :for_entry do
      description "Every record that uses one entry."

      argument :entry_id, :uuid, allow_nil?: false

      filter expr(entry_id == ^arg(:entry_id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :record_type, :string do
      description """
      Which kind of record uses the entry, such as `"show"`. A host chooses its own
      name, and this resource keeps no list of them.

      A string and not an atom, for the reason that `MyHiFi.Cache.Entry` gives for its
      namespace.
      """

      allow_nil? false
      public? true
    end

    attribute :record_id, :uuid do
      description "Which record of that kind. No key covers this, because no column names a resource."
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :entry, MyHiFi.Cache.Entry do
      description "The entry that keeps the bytes. The database enforces this key."
      allow_nil? false
      public? true
      attribute_writable? true
    end
  end

  identities do
    identity :entry_record, [:entry_id, :record_type, :record_id] do
      description "One row for each pair, so saying it twice writes one row."
    end
  end
end
