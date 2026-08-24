defmodule MyHiFi.Cache.Entry do
  @moduledoc """
  One thing that this device holds on disk.

  `AshStorage.BlobResource` gives the `key`, the `filename`, the `content_type`, the
  `byte_size`, the `checksum` and the `metadata`, and it gives the `purge_blob`
  action that removes the file and the row together.

  This resource adds three things of its own.

  - `namespace` says which part of the firmware the entry belongs to, and
    `entry_key` says which thing. The caller chooses what each one means.
  - `key` of the extension holds the path of the file, which is
    `<namespace>/<entry_key>`. `AshStorage` deletes a file by `key`, so that field
    must be the path and not the key of the caller. `Changes.Write` builds it.
  - `last_accessed_at` is what makes the eviction least recently used. **The file
    system cannot answer this.** Nerves mounts ext4 with `relatime`, so `atime`
    moves only when it is a day old, and an entry that a person used an hour ago
    would look cold.
  - `keep?` marks an entry that no eviction may take. A download of an episode that
    holds the place of a person is one of those, and artwork never is. Without it one
    download of 60 MB would remove 50 covers, and a list of shows would remove the
    episode that a person is in the middle of.
  """

  use Ash.Resource,
    otp_app: :my_hi_fi,
    domain: MyHiFi.Cache,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshStorage.BlobResource]

  sqlite do
    table "cache_entries"
    repo MyHiFi.Repo
  end

  blob do
  end

  actions do
    default_accept []

    defaults [:read]

    read :by_key do
      description "Read one entry of one namespace."

      argument :namespace, :string, allow_nil?: false
      argument :entry_key, :string, allow_nil?: false

      get? true
      filter expr(namespace == ^arg(:namespace) and entry_key == ^arg(:entry_key))
    end

    read :by_namespace do
      description "Every entry of one namespace, the most recently used first."

      argument :namespace, :string, allow_nil?: false

      filter expr(namespace == ^arg(:namespace))
      prepare build(sort: [last_accessed_at: :desc])
    end

    read :coldest do
      description """
      The entries that an eviction may take, the least recently used first.

      An entry that a caller marked with `keep?` is absent.
      """

      filter expr(keep? == false)
      prepare build(sort: [last_accessed_at: :asc])
    end

    create :put do
      description """
      Write bytes to the disk and hold the data about them.

      The same namespace and key replace what was there, so a caller may write again
      without a read first.
      """

      upsert? true
      upsert_identity :namespace_entry_key

      accept [:namespace, :entry_key, :content_type, :filename, :keep?]

      argument :bytes, :string do
        description "The bytes of the file. This never reaches the database."
        allow_nil? false
      end

      change MyHiFi.Cache.Entry.Changes.Write
    end

    create :put_file do
      description """
      Move a file that already sits on this partition into the cache.

      An episode of a podcast is 50 MB, and nothing reads that into memory. Both
      paths are under the data partition, so `File.rename/2` copies no byte and the
      file is either in the cache or where it was.

      The caller owns the file until this action answers. A caller that writes a
      file over time therefore writes it somewhere else, and it gives that path here
      when the file is whole. See `MyHiFi.Player.Download`.
      """

      upsert? true
      upsert_identity :namespace_entry_key

      accept [:namespace, :entry_key, :content_type, :filename, :keep?]

      argument :path, :string do
        description "The file to move. It holds the whole thing, and it is not in the cache."
        allow_nil? false
        constraints min_length: 1
      end

      change MyHiFi.Cache.Entry.Changes.Write
    end

    create :put_from_url do
      description """
      Read an address and hold what it gives.

      `entry_key` becomes the hash of the address when a caller names none, so a
      caller that holds one thing for each address needs no key of its own.

      This sets `content_type` from the header of the answer and it reads no byte of
      the body to check that. A caller that needs to know what the bytes are looks at
      them itself. See `MyHiFi.Cache.Entry.Changes.Fetch`.
      """

      upsert? true
      upsert_identity :namespace_entry_key

      accept [:namespace, :entry_key, :content_type, :filename, :keep?]

      argument :url, :string do
        description "The address to read."
        allow_nil? false
        constraints min_length: 1
      end

      argument :max_bytes, :integer do
        description "Refuse a body larger than this. It is absent for no limit."
        allow_nil? true
      end

      argument :bytes, :string, allow_nil?: true

      change MyHiFi.Cache.Entry.Changes.KeyFromUrl
      change MyHiFi.Cache.Entry.Changes.Fetch
      change MyHiFi.Cache.Entry.Changes.Write
    end

    update :touch do
      description """
      Note that something used this entry.

      The eviction reads this, so a caller writes it each time that it serves the
      file.
      """

      change set_attribute(:last_accessed_at, &DateTime.utc_now/0)
    end

    update :keep do
      description "Hold this entry against every eviction."
      change set_attribute(:keep?, true)
    end

    update :release do
      description "Let an eviction take this entry again."
      change set_attribute(:keep?, false)
    end

    action :prune, :map do
      description """
      Remove the coldest entries until the cache is inside its limit.

      A cache that holds nothing but entries to keep stays above the limit, and this
      reports that instead of removing what a person needs.
      """

      run MyHiFi.Cache.Entry.Prune
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :namespace, :string do
      description """
      Which part of the firmware holds this entry, such as `"artwork"`. A caller
      chooses its own, and this resource holds no list of them.

      **A string and not an atom.** A caller invents a namespace, so the database
      holds a name that no code may mention any more. `Ash.Type.Atom` refuses to read
      such a name back, because turning text of a database into an atom fills the
      atom table, and a row of one build would then be unreadable by the next.
      """

      allow_nil? false
      public? true

      # The namespace and the key become the path of a file, so neither may hold a
      # separator or name a parent directory. Without this a caller could write
      # outside the cache. The pattern refuses `.` and `..` as well, because a name
      # must begin with a letter, a number, an underscore, or a hyphen.
      constraints match: ~r/\A[A-Za-z0-9_-][A-Za-z0-9._-]*\z/
    end

    attribute :entry_key, :string do
      description """
      Which thing the caller holds. Artwork uses the hash of an address, and a
      download uses the identifier of an episode.

      `key` of the extension holds the path of the file, and it is this with the
      namespace in front. Both are here so that each filter is one comparison and
      no query builds a string.
      """

      allow_nil? false
      public? true
      constraints min_length: 1, match: ~r/\A[A-Za-z0-9_-][A-Za-z0-9._-]*\z/
    end

    attribute :last_accessed_at, :utc_datetime_usec do
      description "When something last used this entry. The eviction reads it."
      allow_nil? false
      default &DateTime.utc_now/0
      public? true
    end

    attribute :keep?, :boolean do
      description "No eviction may take this entry."
      source :keep
      allow_nil? false
      default false
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :attachments, MyHiFi.Cache.Attachment do
      description """
      Every record that uses this entry. Many may, and that is the point: one file
      serves each of them.
      """

      destination_attribute :entry_id
      public? true
    end
  end

  identities do
    identity :namespace_entry_key, [:namespace, :entry_key] do
      description """
      One entry for each key of each namespace, so two parts of the firmware may
      choose the same key and hold different things.
      """
    end
  end
end
