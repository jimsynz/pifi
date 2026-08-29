defmodule MyHiFi.Podcast.ShowTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Podcast
  alias MyHiFi.Test.Podcasts

  # A show holds the address of the feed and what the last read gave. The title, the
  # author and the picture are on the item that `MyHiFi.Podcast.Fill` writes.
  defp from_feed(overrides \\ %{}) do
    defaults = %{feed_url: "https://example.test/#{System.unique_integer([:positive])}/rss"}

    Podcast.upsert_show_from_feed!(Map.merge(defaults, overrides))
  end

  describe "upsert_from_feed" do
    test "it writes a show" do
      show = from_feed()

      assert show.feed_url =~ "example.test"
      assert show.item_id == nil
      assert show.last_fetched_at
      assert show.last_error == nil
    end

    test "a second read updates the row of the first one" do
      first = from_feed(%{feed_url: "https://example.test/rss"})
      second = from_feed(%{feed_url: "https://example.test/rss"})

      assert second.id == first.id
      assert length(Podcast.list_shows!()) == 1
    end

    test "it leaves the subscription of the person alone" do
      show = from_feed(%{feed_url: "https://example.test/rss"})
      _show = Podcasts.subscribe(show)

      updated = from_feed(%{feed_url: "https://example.test/rss"})

      # The mark is on the item, and a read of the feed writes the row of the show.
      assert [%{id: id}] = Podcast.subscribed_shows!()
      assert id == updated.id
    end

    test "it leaves the identifier of the index alone" do
      Podcast.upsert_show_from_index!(%{
        feed_url: "https://example.test/rss",
        index_id: 920_666
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
          index_id: 920_666
        })

      assert show.index_id == 920_666
      # Only a read of the feed writes this, so a search leaves it absent.
      assert show.last_fetched_at == nil
    end

    test "the feed wins, so a search gives the index identifier and nothing more" do
      from_feed(%{feed_url: "https://example.test/rss"})

      show =
        Podcast.upsert_show_from_index!(%{
          feed_url: "https://example.test/rss",
          index_id: 920_666
        })

      # The index gives the identifier, and it takes nothing else of the feed away.
      assert show.index_id == 920_666
      assert show.last_fetched_at
    end
  end

  describe "the subscription" do
    test "subscribe and unsubscribe move the mark" do
      show = from_feed()

      Podcasts.subscribe(show)
      assert [%{id: id}] = Podcast.subscribed_shows!()
      assert id == show.id

      Podcasts.unsubscribe(show)
      assert Podcast.subscribed_shows!() == []
    end

    test "`subscriptions` reads the subscribed shows alone" do
      _plain = from_feed()
      zebra = from_feed()
      apple = from_feed()

      Podcasts.subscribe(zebra)
      Podcasts.subscribe(apple)

      assert Podcast.subscribed_shows!() |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([zebra.id, apple.id])
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
