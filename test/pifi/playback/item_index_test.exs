defmodule PiFi.Playback.ItemIndexTest do
  @moduledoc """
  Reads the plan of each read of the catalogue, and refuses a full sort and a full scan.

  **An index of a column serves no comparison of an expression.** `kind` is
  `Ash.Type.Atom`, `favourite?` is a boolean and an identifier is `Ash.Type.UUID`, and
  Ash writes `CAST(kind AS TEXT) = CAST(? AS TEXT)` for the first and a cast of its own
  for each of the others. An index of `(source, kind, title COLLATE NOCASE)` therefore
  served no read of this table, and no test said so: the index existed, the name of it
  read correctly, and every branch of every source built a temporary tree over the whole
  source. A branch of a Jellyfin library took 1810 ms on a board.

  The primary key of the table has the same fault. A read by identifier took 370 ms over
  137,557 items, and a press on an album took 5390 ms while the page read the thumbnails
  beside it.

  These tests read what SQLite says it will do, so a read that no index serves fails
  here and not on a board. See the `custom_statements` of `PiFi.Playback.Item`.
  """

  use PiFi.DataCase, async: false

  alias PiFi.Playback.Item
  alias PiFi.Test.QueryPlan

  require Ash.Query

  describe "the plan of a branch of a source" do
    # Every source reads the containers of one kind in the order of the title. Plex and
    # Jellyfin read the artists and the albums this way, and podcasts reads the shows.
    test "a read of one source and one kind, in the order of the title, uses the index" do
      plan =
        Item
        |> Ash.Query.filter(source == "plex" and kind == :container and is_nil(parent_id))
        |> Ash.Query.sort(sorted_title: :asc)
        |> plan_of()

      assert plan =~ "playback_items_source_kind_title_nocase_index"
      QueryPlan.refute_full_sort(plan)
    end

    test "a read in the order of the date uses the index of the date" do
      plan =
        Item
        |> Ash.Query.filter(source == "plex" and kind == :container and not is_nil(parent_id))
        |> Ash.Query.sort(added_at: :desc)
        |> plan_of()

      assert plan =~ "playback_items_source_kind_added_at_index"
      QueryPlan.refute_full_sort(plan)
    end

    test "a read of the marked items uses the index of the mark" do
      plan =
        Item
        |> Ash.Query.filter(source == "plex" and favourite? == true)
        |> Ash.Query.sort(sorted_title: :asc)
        |> plan_of()

      assert plan =~ "playback_items_source_favourite_title_nocase_index"
      QueryPlan.refute_full_sort(plan)
    end
  end

  # An identifier takes a cast as `kind` does, so the primary key of the table and the
  # index of `parent_id` serve neither of these reads. Every press of this firmware
  # makes one of them.
  describe "the plan of a read by identifier" do
    test "a read of one item uses the index of the identifier" do
      id = Ash.UUID.generate()

      plan =
        QueryPlan.while("playback_items", fn -> PiFi.Playback.get_item(id) end)

      assert plan =~ "playback_items_id_text_index"
      QueryPlan.refute_scan(plan)
    end

    test "a read of the items of one container uses the index of the parent" do
      plan =
        Item
        |> Ash.Query.filter(parent_id == ^Ash.UUID.generate())
        |> plan_of()

      assert plan =~ "playback_items_parent_id_text_index"
      QueryPlan.refute_scan(plan)
    end
  end

  # **A list of one genre is a read of the links of that facet**, and not a read of
  # every item of the source. A measurement on a board on 2026-09-16, over 137,557
  # items and a genre of 173 albums, gave 1360 ms for the filter that named the
  # relationship and 128 ms for this one.
  describe "the plan of the items of one facet" do
    test "a read of one facet reads the links of it and no whole source" do
      plan =
        Item
        |> Ash.Query.for_read(:by_facet, %{facet_id: Ash.UUID.generate()})
        |> plan_of()

      assert plan =~ "playback_item_facets_facet_id_index"
      QueryPlan.refute_scan(plan)
    end
  end

  defp plan_of(query), do: QueryPlan.of(query, "playback_items")
end
