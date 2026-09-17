defmodule PiFi.Playback.GroupedCountTest do
  use PiFi.DataCase, async: false

  require Ash.Query

  alias PiFi.Playback
  alias PiFi.Playback.Facet
  alias PiFi.Playback.GroupedCount
  alias PiFi.Playback.Item

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

  defp holds(item, key, value) do
    written = Playback.upsert_facet!(%{key: key, value: value})
    Playback.link_facet!(%{item_id: item.id, facet_id: written.id})
    written
  end

  # Every query of one test reaches this, and the count of them is what says that a page
  # costs one query and not one for each row.
  defp statements(fun) do
    parent = self()
    name = "count-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      name,
      [:pifi, :repo, :query],
      fn _event, _measure, meta, _config -> send(parent, {:query, meta.query}) end,
      nil
    )

    answer = fun.()
    :telemetry.detach(name)

    {answer, drain()}
  end

  defp drain(seen \\ []) do
    receive do
      {:query, query} -> drain([query | seen])
    after
      0 -> Enum.reverse(seen)
    end
  end

  defp counting(statements, table) do
    Enum.count(statements, &(String.contains?(&1, "count(*)") and String.contains?(&1, table)))
  end

  describe "how many items hold a facet" do
    test "it gives the number of items of each value" do
      nz = holds(item(), "country", "NZ").id
      holds(item(), "country", "NZ")
      au = holds(item(), "country", "AU").id

      assert %{^nz => 2, ^au => 1} =
               Facet
               |> Ash.Query.load(:item_count)
               |> Ash.read!()
               |> Map.new(&{&1.id, &1.item_count})
    end

    test "a facet that no item holds gives none" do
      created = Playback.upsert_facet!(%{key: "country", value: "AQ"})

      assert {:ok, %{item_count: 0}} = Ash.get(Facet, created.id, load: [:item_count])
    end

    test "a link that goes takes the count with it" do
      created = item()
      holds(created, "country", "NZ")

      assert :ok = Playback.destroy_item(created)

      assert [%{item_count: 0}] = Facet |> Ash.Query.load(:item_count) |> Ash.read!()
    end
  end

  describe "how many items a container holds" do
    test "it gives the number of children" do
      show = item(%{kind: :container, title: "A show"})
      item(%{parent_id: show.id})
      item(%{parent_id: show.id})
      other = item(%{kind: :container, title: "Another show"})

      counts =
        Item
        |> Ash.Query.filter(kind == :container)
        |> Ash.Query.load(:child_count)
        |> Ash.read!()
        |> Map.new(&{&1.id, &1.child_count})

      assert counts[show.id] == 2
      assert counts[other.id] == 0
    end

    test "a track holds nothing" do
      track = item()

      assert {:ok, %{child_count: 0}} = Playback.get_item(track.id, load: [:child_count])
    end
  end

  # This is the whole reason that this calculation writes SQL. `Ash.count/1` counts one
  # record at a time, and a page holds 100 of them.
  describe "the cost of a page" do
    test "a page of many facets costs one query" do
      for n <- 1..30, do: holds(item(), "tag", "tag-#{n}")

      {facets, statements} =
        statements(fn -> Facet |> Ash.Query.load(:item_count) |> Ash.read!() end)

      assert length(facets) == 30
      assert counting(statements, "playback_item_facets") == 1
    end

    test "a page of many containers costs one query" do
      for n <- 1..30, do: item(%{kind: :container, title: "Show #{n}"})

      {items, statements} =
        statements(fn ->
          Item
          |> Ash.Query.filter(kind == :container)
          |> Ash.Query.load(:child_count)
          |> Ash.read!()
        end)

      assert length(items) == 30
      assert counting(statements, "playback_items") == 1
    end

    test "a page of no rows costs no query at all" do
      {facets, statements} =
        statements(fn -> Facet |> Ash.Query.load(:item_count) |> Ash.read!() end)

      assert facets == []
      assert counting(statements, "playback_item_facets") == 0
    end
  end

  # The names reach the statement as text, so they must never hold anything but a name.
  describe "the names of the table and the column" do
    test "a plain name is accepted" do
      assert {:ok, opts} = GroupedCount.init(table: "playback_items", column: "parent_id")
      assert opts[:table] == "playback_items"
      assert opts[:column] == "parent_id"
    end

    test "anything else is refused" do
      assert {:error, _reason} =
               GroupedCount.init(table: "items; drop table playback_items", column: "parent_id")

      assert {:error, _reason} = GroupedCount.init(table: "playback_items", column: "a-b")
      assert {:error, _reason} = GroupedCount.init(table: :playback_items, column: "parent_id")
    end
  end
end
