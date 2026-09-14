defmodule MyHiFi.Podcast.RefreshTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Event
  alias MyHiFi.Playback
  alias MyHiFi.Podcast
  alias MyHiFi.Podcast.Feed
  alias MyHiFi.Podcast.Fill
  alias MyHiFi.Podcast.Refresh
  alias MyHiFi.Podcast.Show.RefreshAll
  alias MyHiFi.Test.Podcasts

  setup do
    Application.put_env(:my_hi_fi, Feed, plug: {Req.Test, Feed})
    on_exit(fn -> Application.delete_env(:my_hi_fi, Feed) end)

    # Podcasts needs a key of the Podcast Index, so it is out of use until a person
    # sets it up. See `MyHiFi.Source.enabled?/1`.
    MyHiFi.Source.enable(MyHiFi.Source.Podcasts, true)

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
    Podcast.upsert_show_from_feed!(Map.merge(%{feed_url: "https://example.test/rss"}, overrides))
  end

  # The episodes of a show are the children of its item.
  defp episodes_of(show) do
    {:ok, show} = Podcast.get_show(show.id)

    case show.item_id do
      nil -> []
      item_id -> Playback.items_of_parent!(item_id)
    end
  end

  defp item_of(show) do
    {:ok, show} = Podcast.get_show(show.id)
    {:ok, item} = Playback.get_item(show.item_id)

    item
  end

  # An episode is a `MyHiFi.Playback.Item` under the container of the show.
  defp episode(show, number) do
    item = Fill.show(%{feed_url: show.feed_url, title: "Road Work"})
    {:ok, _show} = Podcast.set_show_item(show, %{item_id: item.id})

    Fill.episodes(item, show.feed_url, [
      %{
        guid: "old-#{number}",
        title: "An old episode",
        audio_url: "https://example.test/old-#{number}.mp3",
        mime_type: "audio/mpeg",
        duration_ms: 600_000,
        published_at: DateTime.add(~U[2020-01-01 00:00:00.000000Z], -number, :day),
        description: nil,
        artwork_url: nil
      }
    ])
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
      assert length(episodes_of(created)) == 2
    end

    test "a feed that fails keeps the episodes and holds the reason" do
      created = show()
      episode(created, 1)
      Req.Test.stub(Feed, fn conn -> Plug.Conn.send_resp(conn, 500, "no") end)

      refreshed = Refresh.run(created)

      assert refreshed.last_error =~ "500"
      assert length(episodes_of(created)) == 1
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

      assert length(episodes_of(created)) == keep + 5

      Refresh.prune(item_of(created))

      episodes = episodes_of(created)
      assert length(episodes) == keep
      # A larger number is older, so 1 stays and the last five go.
      assert hd(episodes).source_ref =~ "old-1"
      assert List.last(episodes).source_ref =~ "old-#{keep}"
    end

    test "a show with few episodes loses none" do
      created = show()
      for number <- 1..3, do: episode(created, number)

      Refresh.prune(item_of(created))

      assert length(episodes_of(created)) == 3
    end

    test "it touches no episode of another show" do
      ours = show(%{feed_url: "https://example.test/a/rss"})
      episode(ours, 1)
      theirs = show(%{feed_url: "https://example.test/b/rss"})
      episode(theirs, 1)

      Refresh.prune(item_of(ours))

      assert length(episodes_of(theirs)) == 1
    end
  end

  describe "the scheduled action" do
    test "it reads the subscribed shows and no other" do
      stub_feed(item(1))
      subscribed = show(%{feed_url: "https://example.test/a/rss"})
      subscribed = Podcasts.subscribe(subscribed)
      other = show(%{feed_url: "https://example.test/b/rss"})

      assert {:ok, %{read: 1, failed: 0}} = Podcast.refresh_all_shows()

      assert length(episodes_of(subscribed)) == 1
      assert episodes_of(other) == []
    end

    test "a feed that fails counts as one that failed" do
      Req.Test.stub(Feed, fn conn -> Plug.Conn.send_resp(conn, 500, "no") end)
      subscribed = show()
      _show = Podcasts.subscribe(subscribed)

      assert {:ok, %{read: 0, failed: 1}} = Podcast.refresh_all_shows()
    end

    test "it removes a show that no person subscribed to and nothing has touched" do
      stub_feed(item(1))
      forgotten = show(%{feed_url: "https://example.test/old/rss"})
      aged(forgotten, RefreshAll.stale_after_days() + 1)

      assert {:ok, %{removed: 1}} = Podcast.refresh_all_shows()

      assert Podcast.list_shows!() == []
    end

    test "it keeps a show that a search named lately" do
      stub_feed(item(1))
      show(%{feed_url: "https://example.test/new/rss"})

      assert {:ok, %{removed: 0}} = Podcast.refresh_all_shows()

      assert length(Podcast.list_shows!()) == 1
    end

    test "it keeps a subscribed show however old it is" do
      stub_feed(item(1))
      subscribed = show()
      subscribed = Podcasts.subscribe(subscribed)
      aged(subscribed, RefreshAll.stale_after_days() * 10)

      assert {:ok, %{removed: 0}} = Podcast.refresh_all_shows()

      assert length(Podcast.list_shows!()) == 1
    end

    test "the item of a show goes with the show, and it takes the episodes" do
      stub_feed(item(1))
      forgotten = show(%{feed_url: "https://example.test/old/rss"})
      episode(forgotten, 1)
      aged(forgotten, RefreshAll.stale_after_days() + 1)

      assert {:ok, %{removed: 1}} = Podcast.refresh_all_shows()

      assert Podcast.list_shows!() == []
      assert Ash.count!(MyHiFi.Playback.Item) == 0
    end
  end

  describe "what it tells the rest of the firmware" do
    test "a read that succeeded says that the show changed" do
      stub_feed(item(1))
      created = show()
      Event.subscribe(:source)

      Refresh.run(created)

      assert_receive %Event.Source.Changed{source: MyHiFi.Source.Podcasts, ref: {:show, id}}
      assert id == created.id
    end

    # The episodes did not change, so nothing that shows them needs to read them
    # again. `last_error` changed, and a page that shows the reason reads it when a
    # person asks for it.
    test "a read that failed says nothing" do
      Req.Test.stub(Feed, fn conn -> Plug.Conn.send_resp(conn, 500, "no") end)
      created = show()
      Event.subscribe(:source)

      Refresh.run(created)

      refute_receive %Event.Source.Changed{}
    end
  end

  describe "the schedule" do
    test "Oban holds a worker for it" do
      assert Code.ensure_loaded?(MyHiFi.Podcast.Show.Workers.RefreshAll)
    end

    test "Oban holds a worker for the read of one show" do
      assert Code.ensure_loaded?(MyHiFi.Podcast.Show.Workers.Refresh)
    end

    test "it reads no feed when the podcast source is out of use" do
      stub_feed(item(1))
      subscribed = show()
      _show = Podcasts.subscribe(subscribed)

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
