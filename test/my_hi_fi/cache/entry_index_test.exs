defmodule MyHiFi.Cache.EntryIndexTest do
  @moduledoc """
  Reads the plan of the variants of one entry, and refuses a full scan.

  **Every request for a thumbnail reads this.** `MyHiFi.Artwork.serve_thumbnail/1`
  loads the variants of the entry that a name gives, and a page of a library asks for
  25 thumbnails at one time. Without an index of `variant_of_blob_id` SQLite reads the
  whole table for each of them: a measurement on a board on 2026-09-15, over 10,538
  entries, gave 691 ms for that one read. Ten connections then held the database, and a
  press of a person waited behind them.
  """

  use MyHiFi.DataCase, async: false

  alias MyHiFi.Cache
  alias MyHiFi.Test.QueryPlan

  @png <<0x89, "PNG\r\n", 0x1A, "\n", "the rest of a small image">>

  setup do
    on_exit(fn -> File.rm_rf(Cache.directory()) end)

    :ok
  end

  test "the variants of one entry use the index of the picture" do
    entry = Cache.put!("artwork", "a-name", %{bytes: @png, content_type: "image/png"})

    plan =
      QueryPlan.while(
        "cache_entries",
        fn -> Ash.load!(entry, :variants) end,
        &String.contains?(&1, "variant_of_blob_id")
      )

    assert plan =~ "cache_entries_variant_of_blob_id_index"
    QueryPlan.refute_scan(plan)
  end
end
