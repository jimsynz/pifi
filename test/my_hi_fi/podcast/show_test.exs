defmodule MyHiFi.Podcast.ShowTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Podcast

  defp from_feed(overrides \\ %{}) do
    defaults = %{
      feed_url: "https://example.test/#{System.unique_integer([:positive])}/rss",
      title: "Road Work",
      author: "Dan Benjamin",
      description: "A show about work.",
      artwork_url: "https://example.test/cover.jpg"
    }

    Podcast.upsert_show_from_feed!(Map.merge(defaults, overrides))
  end

  describe "upsert_from_feed" do
    test "it writes a show" do
      show = from_feed()

      assert show.title == "Road Work"
      assert show.author == "Dan Benjamin"
      assert show.subscribed? == false
      assert show.last_fetched_at
      assert show.last_error == nil
    end

    test "a second read updates the row of the first one" do
      first = from_feed(%{feed_url: "https://example.test/rss", title: "Old title"})
      second = from_feed(%{feed_url: "https://example.test/rss", title: "New title"})

      assert second.id == first.id
      assert second.title == "New title"
      assert length(Podcast.list_shows!()) == 1
    end

    test "it leaves the subscription of the person alone" do
      show = from_feed(%{feed_url: "https://example.test/rss"})
      {:ok, _show} = Podcast.subscribe(show)

      updated = from_feed(%{feed_url: "https://example.test/rss", title: "New title"})

      assert updated.subscribed? == true
      assert updated.title == "New title"
    end

    test "it leaves the identifier of the index alone" do
      Podcast.upsert_show_from_index!(%{
        feed_url: "https://example.test/rss",
        index_id: 920_666,
        title: "From the index"
      })

      show = from_feed(%{feed_url: "https://example.test/rss"})

      assert show.index_id == 920_666
    end

    test "a read that succeeds removes the reason of an older failure" do
      show = from_feed(%{feed_url: "https://example.test/rss"})
      {:ok, show} = Podcast.record_show_error(show, %{last_error: "not_rss"})
      assert show.last_error == "not_rss"

      updated = from_feed(%{feed_url: "https://example.test/rss"})

      assert updated.last_error == nil
    end
  end

  describe "upsert_from_index" do
    test "it writes a show that no feed read yet" do
      show =
        Podcast.upsert_show_from_index!(%{
          feed_url: "https://example.test/rss",
          index_id: 920_666,
          title: "The Rest Is History",
          author: "Goalhanger",
          description: "History.",
          artwork_url: "https://example.test/cover.jpg"
        })

      assert show.title == "The Rest Is History"
      assert show.index_id == 920_666
      assert show.last_fetched_at == nil
    end

    test "the feed wins, so a search gives the index identifier and nothing more" do
      from_feed(%{feed_url: "https://example.test/rss", title: "From the feed"})

      show =
        Podcast.upsert_show_from_index!(%{
          feed_url: "https://example.test/rss",
          index_id: 920_666,
          title: "From the index",
          author: "Somebody else"
        })

      assert show.index_id == 920_666
      assert show.title == "From the feed"
      assert show.author == "Dan Benjamin"
    end
  end

  describe "the subscription" do
    test "subscribe and unsubscribe move the mark" do
      show = from_feed()

      {:ok, show} = Podcast.subscribe(show)
      assert show.subscribed? == true

      {:ok, show} = Podcast.unsubscribe(show)
      assert show.subscribed? == false
    end

    test "`subscriptions` reads the subscribed shows alone, and it sorts by the title" do
      _plain = from_feed(%{title: "Not subscribed"})
      zebra = from_feed(%{title: "Zebra"})
      apple = from_feed(%{title: "Apple"})

      {:ok, _show} = Podcast.subscribe(zebra)
      {:ok, _show} = Podcast.subscribe(apple)

      assert Enum.map(Podcast.subscribed_shows!(), & &1.title) == ["Apple", "Zebra"]
    end
  end

  describe "reading one show" do
    test "it reads a show by its address" do
      show = from_feed(%{feed_url: "https://example.test/rss"})

      assert {:ok, found} = Podcast.get_show_by_feed_url("https://example.test/rss")
      assert found.id == show.id
    end

    test "an address that no show holds gives an error" do
      assert {:error, _reason} = Podcast.get_show_by_feed_url("https://example.test/absent")
    end
  end

  describe "record_error" do
    test "it keeps the time of the last read that succeeded" do
      show = from_feed()
      fetched_at = show.last_fetched_at

      {:ok, show} = Podcast.record_show_error(show, %{last_error: "timeout"})

      assert show.last_error == "timeout"
      assert show.last_fetched_at == fetched_at
    end
  end
end
