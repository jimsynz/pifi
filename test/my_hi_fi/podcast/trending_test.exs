defmodule MyHiFi.Podcast.TrendingTest do
  use MyHiFi.DataCase, async: false

  require Ash.Query

  alias MyHiFi.Event
  alias MyHiFi.Playback
  alias MyHiFi.Playback.Item
  alias MyHiFi.Podcast.Index
  alias MyHiFi.Podcast.Trending
  alias MyHiFi.Source.Podcasts

  setup do
    Application.put_env(:my_hi_fi, Index, plug: {Req.Test, Index}, retry: false)
    on_exit(fn -> Application.delete_env(:my_hi_fi, Index) end)

    {:ok, _setting} = MyHiFi.Settings.put(Index.key_setting(), "THEKEY")
    {:ok, _setting} = MyHiFi.Settings.put(Index.secret_setting(), "THESECRET")
    :ok
  end

  defp stub(feeds) do
    Req.Test.stub(Index, fn conn -> Req.Test.json(conn, %{"feeds" => feeds}) end)
  end

  defp feed(number, title, categories \\ %{"55" => "News"}) do
    %{
      "id" => number,
      "url" => "https://example.test/#{number}/rss",
      "title" => title,
      "author" => "Somebody",
      "description" => "A show.",
      "artwork" => "https://example.test/#{number}.jpg",
      "categories" => categories
    }
  end

  defp titles, do: Trending.query() |> Ash.read!() |> Enum.map(& &1.title)

  # A person presses the control of the settings page, and the list that they are
  # looking at changes without another press.
  test "a read that succeeds says that the source changed" do
    Event.subscribe(:source)
    stub([feed(1, "First")])

    assert {:ok, 1} = Trending.run()

    assert_receive %Event.Source.Changed{source: Podcasts, ref: :trending}
  end

  test "a read that failed says nothing" do
    Event.subscribe(:source)
    Req.Test.stub(Index, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, _reason} = Trending.run()

    refute_receive %Event.Source.Changed{}
  end

  test "it writes a show of the index and marks it" do
    stub([feed(1, "First"), feed(2, "Second")])

    assert {:ok, 2} = Trending.run()
    assert titles() == ["First", "Second"]
  end

  # The index gives an order, and `rank` of the item holds it, because a list sorts on
  # a column and no data layer sorts on a facet.
  test "the order of the index is the order that a person reads" do
    stub([feed(1, "Most popular"), feed(2, "Next"), feed(3, "Least")])

    Trending.run()

    assert titles() == ["Most popular", "Next", "Least"]
  end

  # The list moves, and a show that leaves it must not stay on the page.
  test "a show that leaves the list loses the mark and keeps its row" do
    stub([feed(1, "Was popular")])
    Trending.run()
    assert titles() == ["Was popular"]

    stub([feed(2, "Popular now")])
    assert {:ok, 1} = Trending.run()

    assert titles() == ["Popular now"]
    # A person may have subscribed to it, and a search may name it again.
    assert length(Playback.items_of_source!("podcasts")) == 2
  end

  test "a second read makes no second row" do
    stub([feed(1, "First")])

    Trending.run()
    Trending.run()

    assert length(Playback.items_of_source!("podcasts")) == 1
  end

  # A subscription is a mark of the person, and the index knows nothing of it.
  test "it leaves a subscription alone" do
    stub([feed(1, "First")])
    Trending.run()
    [item] = Playback.items_of_source!("podcasts")
    {:ok, _marked} = Playback.set_favourite(item)

    Trending.run()

    assert [%{favourite?: true}] = Playback.favourite_items!()
  end

  test "Trending is a root of the source, and it reads the catalogue" do
    stub([feed(1, "First")])
    Trending.run()

    assert {"Trending", %{query: query, kind: :item}} =
             Enum.find(Podcasts.roots(), &(elem(&1, 0) == "Trending"))

    assert ["First"] = query |> Ash.read!() |> Enum.map(& &1.title)
  end

  # The index gives the categories of each show that it names, so a device learns them
  # from a read that it already makes. Nothing asks the index for a list.
  test "the categories of a show become facets that Categories reads" do
    stub([
      feed(1, "First", %{"55" => "News", "59" => "Politics"}),
      feed(2, "Second", %{"55" => "News"})
    ])

    Trending.run()

    assert {"Categories", %{query: query, kind: :facet}} =
             Enum.find(Podcasts.roots(), &(elem(&1, 0) == "Categories"))

    assert ["News", "Politics"] = query |> Ash.read!() |> Enum.map(& &1.value.value)
  end

  test "a category names the shows that hold it" do
    stub([feed(1, "Newsy", %{"55" => "News"}), feed(2, "Political", %{"59" => "Politics"})])
    Trending.run()

    assert [found] =
             Item
             |> Ash.Query.filter(exists(facets, key == "category" and value == "News"))
             |> Ash.read!()

    assert found.title == "Newsy"
  end

  test "a show that the index gives no category for writes none" do
    stub([feed(1, "First", %{})])

    Trending.run()

    assert [] = Playback.facets_of_key!("category")
  end

  test "a device that holds no key marks nothing, and the action reports none" do
    for key <- [Index.key_setting(), Index.secret_setting()] do
      {:ok, setting} = MyHiFi.Settings.fetch(key)
      MyHiFi.Settings.delete!(setting)
    end

    assert {:error, _reason} = Trending.run()
    assert {:ok, 0} = MyHiFi.Podcast.read_trending_shows()
  end
end
