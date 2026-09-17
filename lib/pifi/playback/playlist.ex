defmodule PiFi.Playback.Playlist do
  @moduledoc """
  A list of tracks that a person made.

  A playlist is the one list of this firmware that a person writes themselves. Every
  other list comes from a service: an album is what the server says it is, and a
  country is what Radio Browser says it is.

  **A playlist takes a track of any source, because `PiFi.Playback.Item` is one
  table.** A station of internet radio, an episode of a podcast and a song of a
  Jellyfin library all sit in one playlist, and nothing here names a source.

  ## It is on the card, and the queue is not

  `PiFi.Playback.Queue` is on ETS, so a restart empties it. A playlist is what a
  person made, and it must be there next week, so it is on the card. A person writes
  a playlist a few times and reads it many times, which is the write pattern that an
  SD card takes.

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
      description "Give this playlist another name."
      accept [:name]
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
      """

      primary? true
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
    identity :name, [:name] do
      description """
      One playlist for each name.

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
