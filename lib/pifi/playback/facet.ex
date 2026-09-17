defmodule PiFi.Playback.Facet do
  @moduledoc """
  One value that a key takes, and the items that link to it.

  A facet is a country, a tag, a codec, a category or a language. `PiFi.Playback.Item`
  links to it through `PiFi.Playback.ItemFacet`, so `country` and `NZ` are written
  one time and 500 stations name that one row.

  The browse tree reads this resource directly: the Countries list is every facet with
  the key `country`, and a press on one gives the items that link to it. A source takes
  no part in that, so the same two rules serve every source.

  ## What is a facet, and what is a column of an item

  **A facet is something that a person would want a list of.** A country, a tag and a
  category are each a short list, and each one covers many items.

  A value that differs for each item is a column of `PiFi.Playback.Item`, and not a
  facet. `published_at` and `duration_ms` are two of those. To make one a facet would
  write one facet row and one link row for each item, which is two rows in the place of
  one column, and it would give a list that is as long as the catalogue.

  ## Give the type when you write

  `value` is a union, and Ash reads the types in the order that the constraints name
  them. A caller that writes a plain term therefore takes the first type that accepts
  it, which is not always the one that it meant. **Write
  `%Ash.Union{type: :integer, value: 128}`** and not `128`.

  A filter needs no tag. `filter(key == "country" and value == "NZ")` works, because
  Ash reads the term against the union.

  The union holds no date, and that is deliberate. A union that names `date` before
  `datetime` takes the time off a datetime and reports no error. Nothing needs a date
  without a time, so nothing can meet that fault.

  ## Counting the items

  `item_count` returns the number of items that link to this facet, and the browse
  page draws it beside the name. Load it, and do not count by hand:

      PiFi.Playback.Facet
      |> Ash.Query.for_read(:by_key, %{key: "country"})
      |> Ash.Query.load(:item_count)
      |> Ash.read!()

  There is no count column, and there is no job that holds one. The count is read at the
  time that a person reads the list, so it is never out of date.

  **AshSqlite holds no aggregate of any kind.** `can?(_, {:aggregate, _type})` gives
  `false`, so `count`, `first` and the rest report "is not aggregatable" for every
  shape of relationship. Do not try to make this an aggregate.
  `PiFi.Playback.GroupedCount` is how `item_count` works, and it says why.
  """

  use Ash.Resource,
    otp_app: :pifi,
    domain: PiFi.Playback,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "playback_facets"
    repo PiFi.Repo
  end

  actions do
    default_accept []

    read :read do
      primary? true
      pagination keyset?: true, required?: false
    end

    read :by_key do
      description """
      Every value that one key takes. This is one container of the browse tree.

      It returns no facet that no item links to. A station that loses its last tag
      leaves a row behind, and a person must not meet an empty container.
      """

      argument :key, :string, allow_nil?: false

      filter expr(key == ^arg(:key) and exists(item_facets, true))
      prepare build(sort: [value: :asc])
      pagination keyset?: true, required?: false
    end

    create :upsert do
      description "Write one facet. The key and the value identify it."

      upsert? true
      upsert_identity :key_value

      accept [:key, :value]
    end

    destroy :destroy do
      primary? true
    end

    action :destroy_orphans, :integer do
      description """
      Remove every facet that no item links to any more. It returns the number that
      it removed.

      `by_key` hides these already, so this reclaims the rows and nothing else. A fill
      calls it when it finishes.
      """

      run PiFi.Playback.Facet.DestroyOrphans
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      description "What the value describes, such as `country` or `codec`."
      allow_nil? false
      public? true
    end

    attribute :value, :union do
      description "The value. Give the type when you write one."

      constraints types: [
                    string: [type: :string],
                    integer: [type: :integer],
                    float: [type: :float],
                    boolean: [type: :boolean],
                    datetime: [type: :utc_datetime_usec]
                  ]

      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :item_facets, PiFi.Playback.ItemFacet do
      public? true
    end

    many_to_many :items, PiFi.Playback.Item do
      through PiFi.Playback.ItemFacet
      source_attribute_on_join_resource :facet_id
      destination_attribute_on_join_resource :item_id
      join_relationship :item_facets
      public? true
    end
  end

  calculations do
    calculate :item_count,
              :integer,
              {PiFi.Playback.GroupedCount, table: "playback_item_facets", column: "facet_id"} do
      description "How many items link to this facet."
    end
  end

  identities do
    identity :key_value, [:key, :value] do
      description "One row for each value of each key."
    end
  end
end
