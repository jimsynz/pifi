defmodule MyHiFi.Playback.ItemFacet do
  @moduledoc """
  One item links to one facet.

  This is the join of `MyHiFi.Playback.Item` and `MyHiFi.Playback.Facet`. It carries two
  keys and nothing else, so a station that carries a country, a language, a codec, a
  bitrate and three tags writes seven small rows and no text of its own.

  A count of the items of one facet reads this table:

      MyHiFi.Playback.ItemFacet
      |> Ash.Query.filter(facet_id == ^facet.id)
      |> Ash.count!()
  """

  use Ash.Resource,
    otp_app: :my_hi_fi,
    domain: MyHiFi.Playback,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "playback_item_facets"
    repo MyHiFi.Repo

    # A link describes one item and one facet, so it goes when either one goes. SQLite
    # does that in one statement, and an Ash change would read and write every row of a
    # station that a sync removes.
    references do
      reference :item, on_delete: :delete
      reference :facet, on_delete: :delete
    end

    # The identity of this resource holds `item_id` first, so no index of it serves a
    # read of `facet_id`. `MyHiFi.Playback.Facet.item_count` reads that column for each
    # row of a page.
    custom_indexes do
      index [:facet_id]
    end
  end

  actions do
    default_accept []

    defaults [:read]

    create :upsert do
      description "Link one item to one facet."

      upsert? true
      upsert_identity :item_facet

      accept [:item_id, :facet_id]
    end

    destroy :destroy do
      primary? true
    end
  end

  attributes do
    uuid_primary_key :id
    timestamps()
  end

  relationships do
    belongs_to :item, MyHiFi.Playback.Item do
      allow_nil? false
      public? true
    end

    belongs_to :facet, MyHiFi.Playback.Facet do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :item_facet, [:item_id, :facet_id] do
      description "One link for each item and facet."
    end
  end
end
