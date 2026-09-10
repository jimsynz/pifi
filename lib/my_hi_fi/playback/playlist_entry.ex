defmodule MyHiFi.Playback.PlaylistEntry do
  @moduledoc """
  One track of one playlist, and its place in the order.

  **This is a relationship and not an identifier**, which is the opposite of
  `MyHiFi.Playback.Queue`. An item and an entry are both in SQLite, so Ash joins the
  two and one query draws a whole playlist with the title, the length and the artwork
  of each row. A queue row is on ETS, and Ash cannot join two data layers.

  A removal of the item takes the entry with it, through the reference below. A
  service that no longer carries a track therefore leaves no row that draws nothing.

  **A track goes in a playlist twice if a person asks twice.** No identity covers the
  pair, because a person who puts one song in a list two times means it.
  """

  use Ash.Resource,
    otp_app: :my_hi_fi,
    domain: MyHiFi.Playback,
    data_layer: AshSqlite.DataLayer

  alias MyHiFi.Playback.Item
  alias MyHiFi.Playback.Playlist

  sqlite do
    table "playback_playlist_entries"
    repo MyHiFi.Repo

    references do
      reference :playlist, on_delete: :delete
      reference :item, on_delete: :delete
    end

    # `entry_count` counts `playlist_id`, and `in_order` reads it. Without the index
    # SQLite reads the whole table for each playlist of the page.
    custom_indexes do
      index [:playlist_id]
    end
  end

  actions do
    default_accept []

    defaults [:read]

    read :in_order do
      description "The entries of one playlist, in the order that they play."

      argument :playlist_id, :uuid, allow_nil?: false

      filter expr(playlist_id == ^arg(:playlist_id))
      prepare build(sort: [position: :asc])
    end

    create :create do
      description """
      Write one entry.

      `MyHiFi.Playback.Playlist.Add` is the only caller, because a place that one
      write chooses by itself makes a gap or two entries of one place.
      """

      accept [:playlist_id, :item_id, :position]
    end

    action :remove, :struct do
      description """
      Take one entry out, and close the gap that it leaves.

      The track stays in the catalogue, and every other playlist keeps it.
      """

      constraints instance_of: __MODULE__

      argument :id, :uuid, allow_nil?: false

      run MyHiFi.Playback.PlaylistEntry.Remove
    end

    action :reorder, :struct do
      description """
      Move one entry to another place, and renumber the rest around it.

      `position` counts from 0, and a place outside the playlist is clamped to the
      nearest end. See `MyHiFi.Playback.Playlist.Order`.
      """

      constraints instance_of: __MODULE__

      argument :id, :uuid, allow_nil?: false
      argument :position, :integer, allow_nil?: false

      run MyHiFi.Playback.PlaylistEntry.Reorder
    end

    update :set_position do
      description "Move this entry to another place."
      accept [:position]
    end

    destroy :destroy do
      primary? true
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :position, :integer do
      description "Where it comes in the order. It counts from 0."
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :playlist, Playlist do
      description "The playlist that this entry belongs to."
      allow_nil? false
      public? true
    end

    belongs_to :item, Item do
      description "The track that this entry names."
      allow_nil? false
      public? true
    end
  end
end
