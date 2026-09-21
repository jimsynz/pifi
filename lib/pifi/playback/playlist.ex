defmodule PiFi.Playback.Playlist do
  @moduledoc """
  A list of tracks that a person made.

  Most of them a person writes themselves. **A playlist takes a track of any source,
  because `PiFi.Playback.Item` is one table.** A station of internet radio, an episode
  of a podcast and a song of a Jellyfin library all sit in one playlist, and nothing
  here names a source.

  ## Where a playlist came from

  `source` says which. `device_source/0` is a playlist that a person made here, and a
  slug such as `plex` is one that a sync copied from a service. A mirrored playlist
  reads the same as any other and **a person cannot change one**: the next read of the
  service would write over whatever they did, so `mine?/1` guards the rename, the add
  and the destroy rather than letting a person lose work.

  `source` cannot be nil, and SQLite is the reason. The identity below covers
  `[:source, :name]`, and SQLite counts two NULLs as different values in a unique
  index, so a nullable source would let a person write `Rock` twice and lose the one
  guarantee that this resource makes.

  `last_seen_at` is how a sync removes what the service no longer has, in the way that
  `PiFi.Plex.Sync.Library` removes an item. A playlist that a person made carries none.

  ## A playlist is not a queue

  `PiFi.Playback.Queue` is one list, and it is what the device is playing now. A
  playlist is what a person made, and there are as many of them as they care to name.

  ## The order

  `PiFi.Playback.PlaylistEntry` carries the place of each track, and
  `PiFi.Playback.Playlist.Order` writes it. `position` counts from 0, and a caller
  cannot make a gap or two entries of one place.

  ## Playing one

  A playlist gives its item identifiers, and `PiFi.Playback.play/2` takes them. The
  queue is therefore the one thing that plays, and the player needs no knowledge of a
  playlist at all.

  `PiFi.Playback.GroupedCount` gives `entry_count`, because **AshSqlite expresses no
  aggregate of any kind**. See that module.
  """

  use Ash.Resource,
    otp_app: :pifi,
    domain: PiFi.Playback,
    data_layer: AshSqlite.DataLayer

  alias PiFi.Playback.PlaylistEntry

  # A playlist that a person made here. It is a value and not nil, and the moduledoc
  # says why.
  @device_source "device"

  @doc """
  The `source` of a playlist that a person made on this device.

      iex> PiFi.Playback.Playlist.device_source()
      "device"
  """
  @spec device_source() :: String.t()
  def device_source, do: @device_source

  @doc """
  Whether a person may change this playlist.

  A mirrored one reads the same and it takes no edit, because the next read of the
  service would write over it.

      iex> PiFi.Playback.Playlist.mine?(%{source: "device"})
      true

      iex> PiFi.Playback.Playlist.mine?(%{source: "plex"})
      false
  """
  @spec mine?(%{source: String.t()}) :: boolean()
  def mine?(%{source: source}), do: source == @device_source

  @doc """
  Refuse a change to a playlist that a service owns.

  `mine?/1` guards the rename and the destroy through a validation, which reads the row
  that it is changing. **The tracks of a playlist are changed through generic actions
  that name an identifier**, so those have nothing to validate and they call this
  instead. `PiFi.Playback.Playlist.Mirror` writes the entries directly and reaches
  neither, which is how a sync still writes what a person cannot.
  """
  @spec ensure_mine(Ash.UUID.t()) :: :ok | {:error, term()}
  def ensure_mine(playlist_id) do
    case Ash.get(__MODULE__, playlist_id, domain: PiFi.Playback) do
      {:ok, playlist} -> refuse_unless_mine(playlist)
      {:error, _reason} -> {:error, :no_such_playlist}
    end
  end

  defp refuse_unless_mine(playlist) do
    if mine?(playlist), do: :ok, else: {:error, {:not_yours, playlist.source}}
  end

  sqlite do
    table "playback_playlists"
    repo PiFi.Repo
  end

  actions do
    default_accept []

    defaults [:read]

    read :in_order do
      description "Every playlist, in the order that a person reads them."
      prepare build(sort: [name: :asc])
    end

    create :create do
      description """
      Make a playlist with a name and nothing in it.

      A second playlist of one name gives an error, because a person who reads two
      rows of one name cannot tell which is which.
      """

      accept [:name]
    end

    update :rename do
      description """
      Give this playlist another name.

      A mirrored one takes no new name: the next read of the service would write the
      old one back, so this refuses rather than losing the change later.
      """

      accept [:name]

      # The guard reads the row that it is changing, so this is not one statement.
      require_atomic? false

      validate &mine/2
    end

    create :mirror do
      description """
      Write a playlist that a sync read from a service, or bring the one it wrote up
      to date.

      **The key is `source_ref` and not the name**, because a service lets a person
      rename a playlist and the row has to follow that rather than make a second one.

      `source_updated_at` is what tells a later read whether the tracks are worth
      reading again, and `last_seen_at` is what keeps this row when the sync removes
      the ones it did not see.
      """

      upsert? true
      upsert_identity :source_playlist

      accept [:name, :source, :source_ref, :source_updated_at, :last_seen_at]
    end

    read :of_source do
      description "The playlists that one service gave this device."

      argument :source, :string, allow_nil?: false

      filter expr(source == ^arg(:source))
      prepare build(sort: [name: :asc])
    end

    read :unseen do
      description """
      The playlists of one service that a read did not see.

      A person removed them on the service, so they go. See
      `PiFi.Plex.Sync.Library`.
      """

      argument :source, :string, allow_nil?: false
      argument :since, :utc_datetime_usec, allow_nil?: false

      filter expr(
               source == ^arg(:source) and
                 (is_nil(last_seen_at) or last_seen_at < ^arg(:since))
             )
    end

    action :add, {:array, :struct} do
      description """
      Put items on the end of this playlist, in the order that they arrive.

      A track that the playlist already carries goes in again, because a person who
      asks for one twice means it. See `PiFi.Playback.Playlist.Add`.
      """

      constraints items: [instance_of: PlaylistEntry]

      argument :playlist_id, :uuid, allow_nil?: false
      argument :item_ids, {:array, :uuid}, allow_nil?: false

      run PiFi.Playback.Playlist.Add
    end

    action :replace_entries, :integer do
      description """
      Put exactly these tracks in this playlist, in this order, and give the count.

      A sync calls this and a person never does. It writes the whole list rather than
      working out a difference: a service gives the order and nothing else, so a
      difference would have to compare every place anyway, and this way a playlist
      that a person reordered on the server reads correctly with no special case.

      **It writes nothing when the playlist already reads this way**, because an SD
      card has a finite number of writes and most reads of a library find a playlist
      that nobody touched. See `PiFi.Playback.Playlist.Mirror`.
      """

      argument :playlist_id, :uuid, allow_nil?: false
      argument :item_ids, {:array, :uuid}, allow_nil?: false

      run PiFi.Playback.Playlist.Mirror
    end

    action :item_ids, {:array, :uuid} do
      description """
      The items of this playlist, in the order that they play.

      `PiFi.Playback.play/2` takes this list. An entry whose item is gone from the
      catalogue is absent, because there is nothing to play for it.
      """

      argument :playlist_id, :uuid, allow_nil?: false

      run PiFi.Playback.Playlist.ItemIds
    end

    destroy :destroy do
      description """
      Remove this playlist, and the entries of it.

      The tracks stay. A playlist names an item and it does not own one.

      A mirrored one takes no removal from a person: the next read of the service
      would write it back, so the control belongs on the service and not here.
      """

      primary? true

      require_atomic? false

      validate &mine/2
    end

    destroy :forget do
      description """
      Remove a playlist that the service no longer has.

      This is the removal that a sync makes, and it is the one path that takes a
      mirrored playlist away.
      """
    end
  end

  # A mirrored playlist reads the same as any other and it takes no edit, because the
  # next read of the service would write over whatever a person did.
  defp mine(changeset, _context) do
    if mine?(changeset.data) do
      :ok
    else
      {:error,
       field: :source,
       message: "comes from %{source} and changes to it belong there",
       vars: [source: changeset.data.source]}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :ci_string do
      description "What a person calls this playlist."
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100, trim?: true, allow_empty?: false
    end

    attribute :source, :string do
      description "`device` for a playlist that a person made, or the slug of a source."
      allow_nil? false
      default @device_source
      public? true
    end

    attribute :source_ref, :string do
      description "What the service calls this playlist. A playlist a person made has none."
      public? true
    end

    attribute :source_updated_at, :utc_datetime_usec do
      description """
      When the service last changed this playlist.

      A sync reads the tracks of a playlist only when this moved, so an hourly read of
      a library that nobody touched writes nothing at all.
      """

      public? true
    end

    attribute :last_seen_at, :utc_datetime_usec do
      description "When a sync last saw this playlist on the service."
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :entries, PlaylistEntry do
      description "The tracks of this playlist, in no order. Read `:in_order` for the order."
      public? true
    end
  end

  calculations do
    calculate :entry_count,
              :integer,
              {PiFi.Playback.GroupedCount,
               table: "playback_playlist_entries", column: "playlist_id"} do
      description "How many tracks this playlist carries."
      public? true
    end
  end

  identities do
    identity :source_playlist, [:source, :source_ref] do
      description """
      One row for each playlist of a service.

      **A service renames a playlist and the row follows**, so the reference is what
      identifies it and the name is not. A playlist that a person made here carries no
      reference, and SQLite counts two NULLs as different values in a unique index, so
      this constrains none of them.
      """
    end

    identity :name, [:source, :name] do
      description """
      One playlist for each name.

      A service names its own, so the source is part of it: a person who calls a
      playlist `Rock` and a Plex server that holds one of that name are two rows.

      **The index compares the bytes, and a filter compares the letters.** `name` is
      an `Ash.Type.CiString`, so AshSqlite writes `COLLATE NOCASE` for a filter and
      for a sort of it, and the list of playlists therefore reads in the order of the
      letters. SQLite compares an index byte by byte, so "Rock" and "rock" are two
      names here. A person who writes both gets two playlists, and the pages read a
      playlist by its identifier and never by its name.
      """
    end
  end
end
