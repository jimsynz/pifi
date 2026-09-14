defmodule MyHiFi.Playback.ItemIndexTest do
  @moduledoc """
  Reads the plan of each branch of a source, and refuses a full sort.

  **An index of a column serves no comparison of an expression.** `kind` is
  `Ash.Type.Atom` and `favourite?` is a boolean, and Ash writes
  `CAST(kind AS TEXT) = CAST(? AS TEXT)` for one and `CAST(favourite AS INTEGER)` for
  the other. An index of `(source, kind, title COLLATE NOCASE)` therefore served no read
  of this table, and no test said so: the index existed, the name of it read correctly,
  and every branch of every source built a temporary tree over the whole source. A
  branch of a Jellyfin library took 1810 ms on a board.

  These tests read what SQLite says it will do, so a sort that no index serves fails
  here and not on a board. See the `custom_statements` of `MyHiFi.Playback.Item`.
  """

  use MyHiFi.DataCase, async: false

  alias MyHiFi.Playback.Item

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
      refute_full_sort(plan)
    end

    test "a read in the order of the date uses the index of the date" do
      plan =
        Item
        |> Ash.Query.filter(source == "plex" and kind == :container and not is_nil(parent_id))
        |> Ash.Query.sort(added_at: :desc)
        |> plan_of()

      assert plan =~ "playback_items_source_kind_added_at_index"
      refute_full_sort(plan)
    end

    test "a read of the marked items uses the index of the mark" do
      plan =
        Item
        |> Ash.Query.filter(source == "plex" and favourite? == true)
        |> Ash.Query.sort(sorted_title: :asc)
        |> plan_of()

      assert plan =~ "playback_items_source_favourite_title_nocase_index"
      refute_full_sort(plan)
    end
  end

  # **A temporary tree over the last term alone is correct.** Ash orders by `id` after
  # the sort of the caller, so that a page of a keyset is stable, and that term orders
  # the rows of one title. A tree over the whole order is the fault that these tests
  # are about.
  defp refute_full_sort(plan) do
    refute plan =~ "USE TEMP B-TREE FOR ORDER BY"
  end

  # The plan must read the statement that Ash writes, and not one that this test writes.
  # The cast above is the whole reason: a statement by hand holds no cast, it uses the
  # index, and it says nothing about what the firmware does.
  defp plan_of(query) do
    Process.register(self(), :item_index_probe)

    handler = "item-index-#{:erlang.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:my_hi_fi, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if metadata[:source] == "playback_items" do
          send(:item_index_probe, {:sql, metadata[:query], metadata[:params]})
        end
      end,
      nil
    )

    try do
      Ash.read!(query, page: [limit: 25, count: false], authorize?: false)

      receive do
        {:sql, sql, params} ->
          {:ok, %{rows: rows}} = MyHiFi.Repo.query("EXPLAIN QUERY PLAN " <> sql, params)

          Enum.map_join(rows, " | ", &List.last/1)
      after
        1000 -> flunk("No statement of `playback_items` reached the telemetry event.")
      end
    after
      :telemetry.detach(handler)
      Process.unregister(:item_index_probe)
    end
  end
end
