defmodule MyHiFi.Source.PodcastsTest do
  use MyHiFi.DataCase, async: false
  use Oban.Testing, repo: MyHiFi.Repo

  alias MyHiFi.Event
  alias MyHiFi.Playback
  alias MyHiFi.Podcast
  alias MyHiFi.Podcast.Feed
  alias MyHiFi.Podcast.Fill
  alias MyHiFi.Podcast.Index
  alias MyHiFi.Settings
  alias MyHiFi.Source.Podcasts

  setup do
    Application.put_env(:my_hi_fi, Index, plug: {Req.Test, Index}, retry: false)
    Application.put_env(:my_hi_fi, Feed, plug: {Req.Test, Feed})

    on_exit(fn ->
      Application.delete_env(:my_hi_fi, Index)
      Application.delete_env(:my_hi_fi, Feed)
    end)

    {:ok, _setting} = Settings.put(Index.key_setting(), "THEKEY")
    {:ok, _setting} = Settings.put(Index.secret_setting(), "THESECRET")
    :ok
  end

  defp stub_index(body) do
    Req.Test.stub(Index, fn conn -> Req.Test.json(conn, body) end)
  end

  defp stub_feed(xml) do
    Req.Test.stub(Feed, fn conn -> Plug.Conn.send_resp(conn, 200, xml) end)
  end

  defp index_feed(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => 920_666,
        "url" => "https://example.test/rss",
        "title" => "Road Work",
        "author" => "Dan Benjamin",
        "description" => "A show about work.",
        "artwork" => "https://example.test/cover.jpg"
      },
      overrides
    )
  end

  defp feed_xml(items) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
      <channel>
        <title>Road Work</title>
        <itunes:author>Dan Benjamin</itunes:author>
        <itunes:image href="https://example.test/cover.jpg" />
    #{items}
      </channel>
    </rss>
    """
  end

  defp item(number, options \\ []) do
    type = Keyword.get(options, :type, "audio/mpeg")
    length = Keyword.get(options, :length, "46739203")

    """
        <item>
          <title>Episode #{number}</title>
          <guid>episode-#{number}</guid>
          <pubDate>Thu, 0#{number} Jun 2022 14:00:00 +0000</pubDate>
          <itunes:duration>48:41</itunes:duration>
          <enclosure url="https://example.test/#{number}.mp3" length="#{length}" type="#{type}" />
        </item>
    """
  end

  defp show(overrides \\ %{}) do
    attributes =
      Map.merge(
        %{
          feed_url: "https://example.test/rss",
          title: "Road Work",
          artwork_url: "https://example.test/cover.jpg"
        },
        overrides
      )

    with_item(Podcast.upsert_show_from_feed!(%{feed_url: attributes.feed_url}), attributes)
  end

  # A show that the index gave and that no feed read reached. `upsert_from_index`
  # writes no `last_fetched_at`, so this is the real path from a search into a
  # show.
  defp unread_show(overrides \\ %{}) do
    attributes = Map.merge(%{feed_url: "https://example.test/rss", title: "Road Work"}, overrides)

    with_item(
      Podcast.upsert_show_from_index!(Map.take(attributes, [:feed_url, :index_id])),
      attributes
    )
  end

  # The source reads `MyHiFi.Playback.Item`, so every show of a test needs its item and
  # the link between the two.
  defp with_item(show, attributes) do
    item = Fill.show(attributes)
    {:ok, show} = Podcast.set_show_item(show, %{item_id: item.id})

    show
  end

  # A `ref` of the source names the item, and not the row of the show.
  # A show that a read reached, long enough ago that the source reads it again. No
  # action writes this attribute, because nothing but a read should.
  defp aged(show, hours) do
    show
    |> Ash.Changeset.for_update(:record_error, %{})
    |> Ash.Changeset.force_change_attribute(
      :last_fetched_at,
      DateTime.add(DateTime.utc_now(), -hours, :hour)
    )
    |> Ash.update!()
  end

  defp episode(show, overrides \\ %{}) do
    attributes =
      Map.merge(
        %{
          guid: "episode-#{System.unique_integer([:positive])}",
          title: "An episode",
          audio_url: "https://example.test/1.mp3",
          mime_type: "audio/mpeg",
          duration_ms: 2_921_000,
          published_at: ~U[2022-06-02 14:00:00Z],
          description: nil,
          artwork_url: nil
        },
        overrides
      )

    {:ok, item} = Playback.get_item(show.item_id)
    Fill.episodes(item, show.feed_url, [attributes])

    Enum.find(
      Playback.items_of_parent!(item.id),
      &(&1.source_ref == Fill.episode_ref(show.feed_url, attributes.guid))
    )
  end

  describe "what the source says about itself" do
    test "it names itself and its icon" do
      assert Podcasts.title() == "Podcasts"
      assert Podcasts.icon() == :podcast
      assert Podcasts.kinds() == [container: "Shows", track: "Episodes"]
    end

    test "its name in an address comes from the module" do
      assert MyHiFi.Source.slug(Podcasts) == "podcasts"
      assert {:ok, Podcasts} = MyHiFi.Source.from_slug("podcasts")
    end

    test "the firmware holds it" do
      assert Podcasts in MyHiFi.Source.all()
    end

    # A show is a feed, and a person can ask for a read of it. See `refresh/1`.
    test "it reads one container again at the request of a person" do
      assert :refresh in Podcasts.capabilities()
    end
  end

  # `opened/1` reads the feed of a copy that is old, and a schedule reads each one every
  # six hours. This is for the person who waits for neither.
  describe "refresh/1" do
    test "it asks for a read of a show that one read reached lately" do
      created = show()

      assert :ok = Podcasts.refresh(Playback.get_item!(created.item_id))

      assert_enqueued(worker: MyHiFi.Podcast.Show.Workers.Refresh)
    end

    test "an entry that names no show gives an error" do
      created = show()
      one = episode(created, %{})

      assert {:error, {:no_such_show, _ref}} = Podcasts.refresh(one)
    end
  end

  # The index holds millions of shows and this device holds the ones that it read, so a
  # search must ask the index. `MyHiFiWeb.SearchLive` matches the text against what the
  # query gives.
  describe "search/1" do
    defp searched(text), do: text |> Podcasts.search() |> Ash.read!() |> Enum.map(& &1.title)

    test "it writes what the index names, so the query finds it" do
      stub_index(%{"feeds" => [index_feed()]})

      assert searched("road work") == ["Road Work"]
    end

    # A person looks for a show to subscribe to it, and for an episode of a show that
    # they hold. `MyHiFiWeb.SearchLive` draws a control to choose between the two.
    test "it gives the shows and the episodes" do
      stub_index(%{"feeds" => [index_feed()]})
      created = unread_show()
      episode(created, %{title: "An episode"})

      assert Enum.sort(searched("road work")) == ["An episode", "Road Work"]
    end

    test "a device with no key still gives what the device holds" do
      :ok = Settings.delete(Settings.fetch!(Index.key_setting()))
      unread_show()

      assert searched("road work") == ["Road Work"]
    end

    test "an index that does not answer still gives what the device holds" do
      Req.Test.stub(Index, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      unread_show()

      assert searched("road work") == ["Road Work"]
    end

    # An empty text reaches no service, because the index would answer with anything.
    test "an empty text asks the index nothing" do
      Req.Test.stub(Index, fn _conn -> raise "the index must not be asked" end)
      unread_show()

      assert searched("   ") == ["Road Work"]
    end
  end

  # `opened/1` is what a page calls when a person opens a show, and it decides whether
  # to read the feed. The page then reads the episodes out of the catalogue, so a read
  # that is slow or that fails still gives a person the episodes that the device holds.
  describe "opening a show" do
    defp titles_of(show) do
      show.item_id |> Playback.items_of_parent!() |> Enum.map(& &1.title)
    end

    defp opened(show), do: Podcasts.opened(Playback.get_item!(show.item_id))

    test "it reads the feed of a show that no read reached yet" do
      stub_feed(feed_xml(item(1) <> item(2)))
      created = unread_show()

      assert :ok = opened(created)

      assert Enum.sort(titles_of(created)) == ["Episode 1", "Episode 2"]
    end

    test "an episode holds the date and the length in its subtitle" do
      stub_feed(feed_xml(item(1)))
      created = unread_show()
      opened(created)

      assert [episode] = Playback.items_of_parent!(created.item_id)
      assert episode.subtitle == "1 Jun 2022, 48 min"
      assert episode.duration_ms == 2_921_000
    end

    test "the cover of the show serves an episode with no artwork of its own" do
      stub_feed(feed_xml(item(1)))
      created = unread_show()
      opened(created)

      assert [episode] = Playback.items_of_parent!(created.item_id, load: [:artwork])
      assert episode.artwork == "https://example.test/cover.jpg"
    end

    test "it reads no feed for a show that one read reached lately" do
      created = show()
      episode(created, %{title: "The one that is already here"})

      Req.Test.stub(Feed, fn _conn -> raise "the feed must not be read" end)

      assert :ok = opened(created)
      assert titles_of(created) == ["The one that is already here"]
      refute_enqueued(worker: MyHiFi.Podcast.Show.Workers.Refresh)
    end

    # A read of a feed takes seconds, and a person pressed a control and waits for a
    # list. They therefore get the episodes that the device holds, and the job writes
    # the newer ones.
    test "an old copy gives its episodes at once, and a job reads the feed" do
      stub_feed(feed_xml(item(1)))
      created = show()
      episode(created, %{title: "The one that is already here"})
      created = aged(created, 2)

      opened(created)

      assert titles_of(created) == ["The one that is already here"]
      assert_enqueued(worker: MyHiFi.Podcast.Show.Workers.Refresh)

      Event.subscribe(:source)
      Oban.drain_queue(queue: :default)

      assert_receive %Event.Source.Changed{source: Podcasts, ref: {:show, id}}
      assert id == created.id

      assert "Episode 1" in titles_of(created)
    end

    # Oban makes a job unique by its arguments, and AshOban puts a `nil` in them, which
    # the SQLite engine of Oban cannot compare. Two opens therefore ask twice. The
    # `where` of the trigger is what holds the reads to one: the job reads the show
    # again, and the first read already made the copy new.
    test "two people opening the same show read the feed one time" do
      stub_feed(feed_xml(item(1)))
      created = aged(show(), 2)

      opened(created)
      opened(created)

      assert %{success: 1, cancelled: 1} = Oban.drain_queue(queue: :default)
    end

    test "a feed that fails keeps the episodes and holds the reason" do
      created = show()
      episode(created, %{title: "An older episode"})
      created = aged(created, 2)

      Req.Test.stub(Feed, fn conn -> Plug.Conn.send_resp(conn, 500, "no") end)

      opened(created)

      assert titles_of(created) == ["An older episode"]

      Oban.drain_queue(queue: :default)

      assert {:ok, show} = Podcast.get_show(created.id)
      assert show.last_error =~ "500"
    end
  end

  describe "resolve" do
    test "an MP3 episode plays from a file that a download writes" do
      created = show()
      one = episode(created)

      assert {:ok, playable} = Podcasts.resolve(one)

      assert playable.uri == "https://example.test/1.mp3"
      assert playable.transport == :download
      assert playable.container == :none
      assert playable.format == :mp3
      assert playable.live? == false
      assert playable.key == one.id
      # An episode at the start begins at the first byte.
      assert playable.position_bytes == 0
      assert playable.headers == []
    end

    test "an episode with a place begins at the byte that it holds" do
      created = show()
      one = episode(created)

      {:ok, one} =
        Playback.store_position(one, %{position_ms: 250_000, position_bytes: 4_000_000})

      assert {:ok, playable} = Podcasts.resolve(one)

      # The byte comes from the reader, so no bitrate turns the time into it.
      assert playable.position_bytes == 4_000_000
      assert playable.position_ms == 250_000
      assert playable.headers == []
    end

    # 11 of 46 real episodes hold more than one bitrate, and a resume by bitrate
    # landed as much as 1994.6 s from the mark. Nothing here reads a bitrate, a
    # length, or a duration.
    test "the length and the duration of the feed decide nothing" do
      created = show()
      one = episode(created, %{byte_length: 99, duration_ms: 99})

      {:ok, one} =
        Playback.store_position(one, %{position_ms: 250_000, position_bytes: 4_000_000})

      assert {:ok, playable} = Podcasts.resolve(one)
      assert playable.position_bytes == 4_000_000
    end

    test "an episode that a person never played begins at the first byte" do
      created = show()
      one = episode(created)
      {:ok, one} = Playback.store_position(one, %{position_ms: 250_000})

      assert {:ok, playable} = Podcasts.resolve(one)

      # A place with no byte cannot say where in the file it is, so this begins
      # again. Repeating some audio is better than stepping over some.
      assert playable.position_bytes == 0
    end

    test "an AAC episode plays" do
      created = show()
      one = episode(created, %{mime_type: "audio/aac"})

      assert {:ok, playable} = Podcasts.resolve(one)
      assert playable.format == :aac
    end

    # `MyHiFi.Podcast.CarryPlaces` writes an episode that holds the place of a person
    # and nothing else, and the next read of the feed fills it. A person can press it
    # first.
    test "an episode that no read has filled names the reason, and it does not raise" do
      created = show()
      one = episode(created, %{})

      assert {:error, {:not_read_yet, title}} = Podcasts.resolve(%{one | url: nil})
      assert title == one.title

      assert {:error, {:not_read_yet, _title}} = Podcasts.resolve(%{one | format: nil})
    end

    test "an m4a episode names the reason that it cannot play" do
      created = show()
      one = episode(created, %{mime_type: "audio/x-m4a"})

      # The fill reads the type of the enclosure, so the source holds no mime type by
      # this point. The title says which episode cannot play.
      assert {:error, {:unsupported_format, "An episode"}} =
               Podcasts.resolve(one)
    end
  end

  # The mark is on the item, and this source holds no control of its own for it. A page
  # calls `MyHiFi.Playback.set_favourite/1`, and the read of the shows joins to it.
  describe "how many episodes the card holds" do
    test "it holds three of the newest until a person says otherwise" do
      assert Podcasts.hold_limit() == 3
    end

    test "a person changes the number" do
      assert {:ok, message} = Podcasts.put_settings(%{"episodes" => "5"})

      assert message =~ "5 newest episodes"
      assert Podcasts.hold_limit() == 5
    end

    test "none is a number too" do
      assert {:ok, message} = Podcasts.put_settings(%{"episodes" => "0"})

      assert message =~ "no episode"
      assert Podcasts.hold_limit() == 0
    end

    test "a number that is not one, and one past the ceiling, are refused" do
      assert {:error, message} = Podcasts.put_settings(%{"episodes" => "lots"})
      assert message =~ "whole number from 0 to 20"

      assert {:error, _message} = Podcasts.put_settings(%{"episodes" => "21"})
      assert {:error, _message} = Podcasts.put_settings(%{"episodes" => "-1"})

      assert Podcasts.hold_limit() == 3
    end

    # **The key and the secret are write only, so the form draws them empty every
    # time.** A person who changed this number alone would otherwise have to type both
    # of them again.
    test "the number changes without the key and the secret" do
      Settings.put!(Index.key_setting(), "a-key")
      Settings.put!(Index.secret_setting(), "a-secret")

      assert {:ok, _message} =
               Podcasts.put_settings(%{"key" => "", "secret" => "", "episodes" => "2"})

      assert Podcasts.hold_limit() == 2
      assert {:ok, %{value: "a-key"}} = Settings.fetch(Index.key_setting())
    end

    # A person who gave one of the two meant to give both, and the answer says so.
    test "one of the key and the secret is still an error" do
      assert {:error, message} =
               Podcasts.put_settings(%{"key" => "a-key", "secret" => "", "episodes" => "2"})

      assert message =~ "both the key and the secret"
    end

    # The field says what the device holds now, so a person reads it before they change
    # it. It is not write only: no key and no secret is in it.
    test "the settings page reads the number back" do
      Settings.put!("podcasts.hold_episodes", "7")

      assert %{value: "7", type: :number, write_only?: false} =
               Podcasts.settings() |> Enum.find(&(&1.key == "episodes"))
    end
  end

  describe "the subscription" do
    test "the mark on the item of a show subscribes to it, and it removes that" do
      created = show()
      item = Playback.get_item!(created.item_id)

      {:ok, item} = Playback.set_favourite(item)
      assert [%{id: id}] = Podcast.subscribed_shows!()
      assert id == created.id

      {:ok, _item} = Playback.clear_favourite(item)
      assert [] == Podcast.subscribed_shows!()
    end
  end
end
