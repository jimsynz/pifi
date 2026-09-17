defmodule PiFi.Playback.FacetTest do
  use PiFi.DataCase, async: false

  require Ash.Query

  alias PiFi.Playback
  alias PiFi.Playback.Facet
  alias PiFi.Playback.Item
  alias PiFi.Playback.ItemFacet

  defp item(overrides \\ %{}) do
    Playback.upsert_item!(
      Map.merge(
        %{
          source: "internet-radio",
          source_ref: "station-#{System.unique_integer([:positive])}",
          title: "A station"
        },
        overrides
      )
    )
  end

  defp facet(key, value) do
    Playback.upsert_facet!(%{key: key, value: value})
  end

  defp holds(item, key, value) do
    written = facet(key, value)
    Playback.link_facet!(%{item_id: item.id, facet_id: written.id})
    written
  end

  defp values_of(key) do
    key
    |> Playback.facets_of_key!()
    |> Enum.map(& &1.value.value)
  end

  describe "the value, and its type" do
    test "each type of the union goes in and comes out as it went" do
      for {type, value} <- [
            string: "NZ",
            integer: 128,
            float: 96.5,
            boolean: true,
            datetime: ~U[2022-06-02 14:00:00.000000Z]
          ] do
        written = facet(to_string(type), %Ash.Union{type: type, value: value})

        assert written.value == %Ash.Union{type: type, value: value},
               "#{type} did not come back as it went"
      end
    end

    # The union holds no date, so nothing can lose the time off a datetime. A union
    # that names `date` before `datetime` does exactly that, and it reports no error.
    test "a datetime keeps its time" do
      at = ~U[2022-06-02 14:30:15.000000Z]

      written = facet("published", %Ash.Union{type: :datetime, value: at})

      assert written.value.type == :datetime
      assert written.value.value == at
    end

    test "a value with no type takes the first type that accepts it" do
      written = facet("country", "NZ")

      assert written.value.type == :string
      assert written.value.value == "NZ"
    end
  end

  describe "one row for each value" do
    # This is the point of the join. `country` and `NZ` are written one time, and every
    # station of that country names the one row.
    test "many items hold one facet, and the facet is written one time" do
      first = item()
      second = item()

      nz = holds(first, "country", "NZ")
      again = holds(second, "country", "NZ")

      assert nz.id == again.id
      assert Ash.count!(Facet) == 1
      assert Ash.count!(ItemFacet) == 2
    end

    test "one item holds many values of one key" do
      created = item()

      holds(created, "tag", "news")
      holds(created, "tag", "talk")

      assert {:ok, read} = Playback.get_item(created.id, load: [:facets])
      assert length(read.facets) == 2
    end

    test "a second link of the same pair makes no second row" do
      created = item()
      written = facet("country", "NZ")

      Playback.link_facet!(%{item_id: created.id, facet_id: written.id})
      Playback.link_facet!(%{item_id: created.id, facet_id: written.id})

      assert Ash.count!(ItemFacet) == 1
    end
  end

  describe "counting the items of a facet" do
    # There is no count column, because AshSqlite holds no aggregate of any kind.
    test "a count of the join gives the number of items" do
      nz = facet("country", "NZ")
      au = facet("country", "AU")

      for _n <- 1..3 do
        Playback.link_facet!(%{item_id: item().id, facet_id: nz.id})
      end

      Playback.link_facet!(%{item_id: item().id, facet_id: au.id})

      assert Ash.count!(Ash.Query.filter(ItemFacet, facet_id == ^nz.id)) == 3
      assert Ash.count!(Ash.Query.filter(ItemFacet, facet_id == ^au.id)) == 1
    end

    test "a count reaches through the join to the facet" do
      created = item()
      holds(created, "country", "NZ")
      holds(created, "tag", "news")

      assert Ash.count!(Ash.Query.filter(ItemFacet, facet.key == "country")) == 1
    end
  end

  describe "a container of the browse tree" do
    test "it lists every value of one key, and it keeps the keys apart" do
      created = item()
      other = item()

      holds(created, "country", "NZ")
      holds(other, "country", "AU")
      holds(created, "tag", "news")

      assert values_of("country") == ["AU", "NZ"]
      assert values_of("tag") == ["news"]
    end

    # A person must not meet a container that holds nothing.
    test "it hides a facet that no item holds" do
      created = item()
      holds(created, "tag", "news")
      facet("tag", "nothing holds this")

      assert values_of("tag") == ["news"]
    end

    test "an item that goes takes its links, and its facets go quiet" do
      created = item()
      holds(created, "country", "NZ")

      assert values_of("country") == ["NZ"]

      assert :ok = Playback.destroy_item(created)

      assert Ash.count!(ItemFacet) == 0
      assert values_of("country") == []
      # The row is still there, and nothing shows it.
      assert Ash.count!(Facet) == 1
    end
  end

  describe "removing the orphans" do
    test "it removes a facet that no item holds, and it keeps the rest" do
      created = item()
      holds(created, "country", "NZ")
      facet("country", "AU")

      assert {:ok, 1} = Playback.destroy_orphan_facets()

      assert values_of("country") == ["NZ"]
      assert Ash.count!(Facet) == 1
    end

    test "it removes nothing when every facet is held" do
      created = item()
      holds(created, "country", "NZ")

      assert {:ok, 0} = Playback.destroy_orphan_facets()
      assert Ash.count!(Facet) == 1
    end
  end

  describe "finding items by a facet" do
    test "a filter on a key and a value finds the item that holds it" do
      wanted = item(%{title: "RNZ National"})
      other = item(%{title: "ABC Sydney"})

      holds(wanted, "country", "NZ")
      holds(other, "country", "AU")

      assert [found] =
               Item
               |> Ash.Query.filter(exists(facets, key == "country" and value == "NZ"))
               |> Ash.read!()

      assert found.title == "RNZ National"
    end

    test "a filter compares a number as a number" do
      loud = item(%{title: "Loud"})
      quiet = item(%{title: "Quiet"})

      holds(loud, "bitrate", %Ash.Union{type: :integer, value: 320})
      holds(quiet, "bitrate", %Ash.Union{type: :integer, value: 64})

      assert [found] =
               Item
               |> Ash.Query.filter(exists(facets, key == "bitrate" and value[:value] > 200))
               |> Ash.read!()

      assert found.title == "Loud"
    end
  end
end
