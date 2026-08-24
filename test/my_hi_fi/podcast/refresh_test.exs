defmodule MyHiFi.Podcast.RefreshTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Podcast
  alias MyHiFi.Podcast.Feed
  alias MyHiFi.Podcast.Refresh
  alias MyHiFi.Podcast.Show.RefreshAll

  setup do
    Application.put_env(:my_hi_fi, Feed, plug: {Req.Test, Feed})
    on_exit(fn -> Application.delete_env(:my_hi_fi, Feed) end)
    :ok
  end

  defp stub_feed(items) do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
      <channel>
        <title>Road Work</title>
    #{items}
      </channel>
    </rss>
    """

    Req.Test.stub(Feed, fn conn -> Plug.Conn.send_resp(conn, 200, xml) end)
  end

  defp item(number) do
    """
        <item>
          <title>Episode #{number}</title>
          <guid>episode-#{number}</guid>
          <enclosure url="https://example.test/#{number}.mp3" length="1" type="audio/mpeg" />
        </item>
    """
  end

  defp show(overrides \\ %{}) do
    Podcast.upsert_show_from_feed!(
      Map.merge(
        %{feed_url: "https://example.test/rss", title: "Road Work"},
        overrides
      )
    )
  end

  defp episode(show, number) do
    Podcast.upsert_episode_from_feed!(%{
      show_id: show.id,
      guid: "old-#{number}",
      title: "Old episode #{number}",
      audio_url: "https://example.test/old-#{number}.mp3",
      # The newest comes first, so a larger number is older.
      published_at: DateTime.add(~U[2026-01-01 00:00:00Z], -number, :day)
    })
  end

  # No action writes this, because nothing but a change should.
  defp aged(show, days) do
    show
    |> Ash.Changeset.for_update(:record_error, %{})
    |> Ash.Changeset.force_change_attribute(
      :updated_at,
      DateTime.add(DateTime.utc_now(), -days, :day)
    )
    |> Ash.update!()
  end

  describe "run/1" do
    test "it writes the episodes of a feed" do
      stub_feed(item(1) <> item(2))
      created = show()

      refreshed = Refresh.run(created)

      assert refreshed.last_error == nil
      assert length(Podcast.episodes_of_show!(created.id)) == 2
    end

    test "a feed that fails keeps the episodes and holds the reason" do
      created = show()
      episode(created, 1)
      Req.Test.stub(Feed, fn conn -> Plug.Conn.send_resp(conn, 500, "no") end)

      refreshed = Refresh.run(created)

      assert refreshed.last_error =~ "500"
      assert length(Podcast.episodes_of_show!(created.id)) == 1
    end

    test "a read that succeeds removes the reason of an older failure" do
      created = show()
      {:ok, created} = Podcast.record_show_error(created, %{last_error: "not_rss"})
      stub_feed(item(1))

      refreshed = Refresh.run(created)

      assert refreshed.last_error == nil
    end
  end

  describe "prune/1" do
    test "it keeps the newest episodes and removes the rest" do
      created = show()
      keep = Refresh.keep()
      for number <- 1..(keep + 5), do: episode(created, number)

      assert length(Podcast.episodes_of_show!(created.id)) == keep + 5

      Refresh.prune(created)

      episodes = Podcast.episodes_of_show!(created.id)
      assert length(episodes) == keep
      # A larger number is older, so 1 stays and the last five go.
      assert hd(episodes).guid == "old-1"
      assert List.last(episodes).guid == "old-#{keep}"
    end

    test "a show with few episodes loses none" do
      created = show()
      for number <- 1..3, do: episode(created, number)

      Refresh.prune(created)

      assert length(Podcast.episodes_of_show!(created.id)) == 3
    end

    test "it touches no episode of another show" do
      ours = show(%{feed_url: "https://example.test/a/rss"})
      theirs = show(%{feed_url: "https://example.test/b/rss", title: "Another"})
      episode(theirs, 1)

      Refresh.prune(ours)

      assert length(Podcast.episodes_of_show!(theirs.id)) == 1
    end
  end

  describe "the scheduled action" do
    test "it reads the subscribed shows and no other" do
      stub_feed(item(1))
      subscribed = show(%{feed_url: "https://example.test/a/rss", title: "Subscribed"})
      {:ok, subscribed} = Podcast.subscribe(subscribed)
      other = show(%{feed_url: "https://example.test/b/rss", title: "Not subscribed"})

      assert {:ok, %{read: 1, failed: 0}} = Podcast.refresh_all_shows()

      assert length(Podcast.episodes_of_show!(subscribed.id)) == 1
      assert Podcast.episodes_of_show!(other.id) == []
    end

    test "a feed that fails counts as one that failed" do
      Req.Test.stub(Feed, fn conn -> Plug.Conn.send_resp(conn, 500, "no") end)
      subscribed = show()
      {:ok, _show} = Podcast.subscribe(subscribed)

      assert {:ok, %{read: 0, failed: 1}} = Podcast.refresh_all_shows()
    end

    test "it removes a show that no person subscribed to and nothing has touched" do
      stub_feed(item(1))
      forgotten = show(%{feed_url: "https://example.test/old/rss", title: "Forgotten"})
      aged(forgotten, RefreshAll.stale_after_days() + 1)

      assert {:ok, %{removed: 1}} = Podcast.refresh_all_shows()

      assert Podcast.list_shows!() == []
    end

    test "it keeps a show that a search named lately" do
      stub_feed(item(1))
      show(%{feed_url: "https://example.test/new/rss", title: "Looked at today"})

      assert {:ok, %{removed: 0}} = Podcast.refresh_all_shows()

      assert length(Podcast.list_shows!()) == 1
    end

    test "it keeps a subscribed show however old it is" do
      stub_feed(item(1))
      subscribed = show()
      {:ok, subscribed} = Podcast.subscribe(subscribed)
      aged(subscribed, RefreshAll.stale_after_days() * 10)

      assert {:ok, %{removed: 0}} = Podcast.refresh_all_shows()

      assert length(Podcast.list_shows!()) == 1
    end

    test "the episodes of a show go before the show, because SQLite holds the key" do
      stub_feed(item(1))
      forgotten = show(%{feed_url: "https://example.test/old/rss", title: "Forgotten"})
      episode(forgotten, 1)
      aged(forgotten, RefreshAll.stale_after_days() + 1)

      assert {:ok, %{removed: 1}} = Podcast.refresh_all_shows()

      assert Podcast.list_shows!() == []
      assert Ash.count!(Podcast.Episode) == 0
    end
  end

  describe "the schedule" do
    test "Oban holds a worker for it" do
      assert Code.ensure_loaded?(MyHiFi.Podcast.Show.Workers.RefreshAll)
    end

    test "it reads no feed when the podcast source is out of use" do
      stub_feed(item(1))
      subscribed = show()
      {:ok, _show} = Podcast.subscribe(subscribed)

      MyHiFi.Source.enable(MyHiFi.Source.Podcasts, false)

      on_exit(fn ->
        {:ok, setting} =
          MyHiFi.Settings.fetch(MyHiFi.Source.enabled_key(MyHiFi.Source.Podcasts))

        MyHiFi.Settings.delete!(setting)
      end)

      assert {:ok, %{read: 0, skipped?: true}} = Podcast.refresh_all_shows()
    end
  end
end
