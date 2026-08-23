defmodule MyHiFi.Source.PodcastsTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Player.Mp3
  alias MyHiFi.Podcast
  alias MyHiFi.Podcast.Feed
  alias MyHiFi.Podcast.Index
  alias MyHiFi.Settings
  alias MyHiFi.Source.Podcasts

  setup do
    Application.put_env(:my_hi_fi, Index, plug: {Req.Test, Index}, retry: false)
    Application.put_env(:my_hi_fi, Feed, plug: {Req.Test, Feed})
    Application.put_env(:my_hi_fi, Mp3, plug: {Req.Test, Mp3})

    on_exit(fn ->
      Application.delete_env(:my_hi_fi, Index)
      Application.delete_env(:my_hi_fi, Feed)
      Application.delete_env(:my_hi_fi, Mp3)
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

  # Audio with no ID3 tag, and one MP3 frame header of 128 kbps at the start. A
  # resume reads the bitrate from this.
  defp stub_audio(bitrate_byte \\ 0x90) do
    audio = <<0xFF, 0xFB, bitrate_byte, 0x00>> <> :binary.copy(<<0>>, 4092)

    Req.Test.stub(Mp3, fn conn ->
      ["bytes=" <> range] = Plug.Conn.get_req_header(conn, "range")
      [first, last] = String.split(range, "-")
      first = String.to_integer(first)
      last = min(String.to_integer(last), byte_size(audio) - 1)

      Plug.Conn.send_resp(conn, 206, binary_part(audio, first, last - first + 1))
    end)
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
    Podcast.upsert_show_from_feed!(
      Map.merge(
        %{
          feed_url: "https://example.test/rss",
          title: "Road Work",
          artwork_url: "https://example.test/cover.jpg"
        },
        overrides
      )
    )
  end

  # A show that the index gave and that no feed read reached. `upsert_from_index`
  # writes no `last_fetched_at`, so this is the real path from a search into a
  # show.
  defp unread_show(overrides \\ %{}) do
    Podcast.upsert_show_from_index!(
      Map.merge(
        %{feed_url: "https://example.test/rss", title: "Road Work"},
        overrides
      )
    )
  end

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
    Podcast.upsert_episode_from_feed!(
      Map.merge(
        %{
          show_id: show.id,
          guid: "episode-#{System.unique_integer([:positive])}",
          title: "An episode",
          audio_url: "https://example.test/1.mp3",
          mime_type: "audio/mpeg",
          byte_length: 46_739_203,
          duration_ms: 2_921_000,
          published_at: ~U[2022-06-02 14:00:00Z]
        },
        overrides
      )
    )
  end

  describe "what the source says about itself" do
    test "it names itself and its icon" do
      assert Podcasts.title() == "Podcasts"
      assert Podcasts.icon() == :podcast
      assert Podcasts.root() == :root
    end

    test "its name in an address comes from the module" do
      assert MyHiFi.Source.slug(Podcasts) == "podcasts"
      assert {:ok, Podcasts} = MyHiFi.Source.from_slug("podcasts")
    end

    test "the firmware holds it" do
      assert Podcasts in MyHiFi.Source.all()
    end
  end

  describe "the top of the tree" do
    test "it holds three branches, and none of them carries a mark" do
      assert {:ok, %{entries: entries, cursor: nil}} = Podcasts.browse(:root)

      assert Enum.map(entries, fn {:container, c} -> c.title end) == [
               "Subscriptions",
               "Trending",
               "Categories"
             ]

      assert Enum.all?(entries, fn {:container, c} -> c.favourite? == nil end)
    end
  end

  describe "subscriptions" do
    test "it lists the shows that a person subscribed to, and each one is marked" do
      subscribed = show(%{feed_url: "https://example.test/a/rss", title: "Subscribed"})
      {:ok, _show} = Podcast.subscribe(subscribed)
      show(%{feed_url: "https://example.test/b/rss", title: "Not subscribed"})

      assert {:ok, %{entries: [{:container, container}]}} = Podcasts.browse(:subscriptions)

      assert container.title == "Subscribed"
      assert container.favourite? == true
      assert container.ref == {:show, subscribed.id}
    end

    test "it needs no key" do
      :ok = Settings.delete(Settings.fetch!(Index.key_setting()))

      assert {:ok, %{entries: []}} = Podcasts.browse(:subscriptions)
    end
  end

  describe "trending and the categories" do
    test "trending writes a row for each show and gives the containers" do
      stub_index(%{"feeds" => [index_feed()]})

      assert {:ok, %{entries: [{:container, container}]}} = Podcasts.browse(:trending)

      assert container.title == "Road Work"
      assert container.favourite? == false
      assert container.artwork == "https://example.test/cover.jpg"

      assert [%{index_id: 920_666}] = Podcast.list_shows!()
    end

    test "a show that a person subscribed to keeps its mark in the trending list" do
      subscribed = show(%{feed_url: "https://example.test/rss"})
      {:ok, _show} = Podcast.subscribe(subscribed)

      stub_index(%{"feeds" => [index_feed()]})

      assert {:ok, %{entries: [{:container, container}]}} = Podcasts.browse(:trending)
      assert container.favourite? == true
    end

    test "the categories become one container each" do
      stub_index(%{"feeds" => [%{"id" => 55, "name" => "News"}, %{"id" => 9, "name" => "Arts"}]})

      assert {:ok, %{entries: entries}} = Podcasts.browse(:categories)

      assert Enum.map(entries, fn {:container, c} -> {c.ref, c.title} end) == [
               {{:category, "Arts"}, "Arts"},
               {{:category, "News"}, "News"}
             ]
    end

    test "one category names itself to the index" do
      test = self()

      Req.Test.stub(Index, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test, {:params, conn.params})
        Req.Test.json(conn, %{"feeds" => []})
      end)

      assert {:ok, %{entries: []}} = Podcasts.browse({:category, "History"})

      assert_receive {:params, %{"cat" => "History"}}
    end

    test "a device with no key gives that reason" do
      :ok = Settings.delete(Settings.fetch!(Index.key_setting()))

      assert {:error, :no_api_key} = Podcasts.browse(:trending)
      assert {:error, :no_api_key} = Podcasts.browse(:categories)
      assert {:error, :no_api_key} = Podcasts.search("history")
    end
  end

  describe "search" do
    test "it gives the shows of the index as containers" do
      stub_index(%{"feeds" => [index_feed()]})

      assert {:ok, %{entries: [{:container, container}]}} = Podcasts.search("road work")
      assert container.title == "Road Work"
    end
  end

  describe "the episodes of a show" do
    test "it reads the feed of a show that no read reached yet" do
      stub_feed(feed_xml(item(1) <> item(2)))
      created = unread_show()

      assert {:ok, %{entries: entries}} = Podcasts.browse({:show, created.id})

      assert Enum.map(entries, fn {:track, t} -> t.title end) == ["Episode 2", "Episode 1"]
      assert length(Podcast.episodes_of_show!(created.id)) == 2
    end

    test "an episode holds the date and the length in its subtitle" do
      stub_feed(feed_xml(item(1)))
      created = unread_show()

      assert {:ok, %{entries: [{:track, track}]}} = Podcasts.browse({:show, created.id})

      assert track.subtitle == "1 Jun 2022, 48 min"
      assert track.duration_ms == 2_921_000
      # A person subscribes to the show, so an episode carries no mark.
      assert track.favourite? == nil
    end

    test "the cover of the show serves an episode with no artwork of its own" do
      stub_feed(feed_xml(item(1)))
      created = unread_show()

      assert {:ok, %{entries: [{:track, track}]}} = Podcasts.browse({:show, created.id})
      assert track.artwork == "https://example.test/cover.jpg"
    end

    test "it reads no feed for a show that one read reached lately" do
      created = show()
      episode(created, %{title: "The one that is already here"})

      Req.Test.stub(Feed, fn _conn -> raise "the feed must not be read" end)

      assert {:ok, %{entries: [{:track, track}]}} = Podcasts.browse({:show, created.id})
      assert track.title == "The one that is already here"
    end

    test "a feed that fails keeps the episodes and holds the reason" do
      created = show()
      episode(created, %{title: "An older episode"})
      created = aged(created, 2)

      Req.Test.stub(Feed, fn conn -> Plug.Conn.send_resp(conn, 500, "no") end)

      assert {:ok, %{entries: [{:track, track}]}} = Podcasts.browse({:show, created.id})
      assert track.title == "An older episode"

      assert {:ok, show} = Podcast.get_show(created.id)
      assert show.last_error =~ "500"
    end

    test "a show that no row holds gives an error" do
      assert {:error, _reason} = Podcasts.browse({:show, Ash.UUID.generate()})
    end

    test "a container that this source does not know gives an error" do
      assert {:error, {:no_such_container, :nonsense}} = Podcasts.browse(:nonsense)
    end
  end

  describe "one episode" do
    test "it describes an episode, and it names the show for the artwork" do
      created = show()
      one = episode(created, %{title: "An episode", artwork_url: nil})

      assert {:ok, track} = Podcasts.track({:episode, one.id})
      assert track.title == "An episode"
      assert track.artwork == "https://example.test/cover.jpg"
    end

    test "a ref that names no track gives an error" do
      assert {:error, {:not_a_track, :root}} = Podcasts.track(:root)
      assert {:error, {:not_a_track, :root}} = Podcasts.resolve(:root)
    end
  end

  describe "resolve" do
    test "an MP3 episode plays over HTTP with no container" do
      created = show()
      one = episode(created)

      assert {:ok, playable} = Podcasts.resolve({:episode, one.id})

      assert playable.uri == "https://example.test/1.mp3"
      assert playable.transport == :http
      assert playable.container == :none
      assert playable.format == :mp3
      assert playable.live? == false
      # An episode at the start needs no range.
      assert playable.headers == []
    end

    test "an episode with a place asks for the bytes from that place" do
      stub_audio()
      created = show()
      one = episode(created)
      {:ok, one} = Podcast.store_position(one, %{position_ms: 250_000})

      assert {:ok, playable} = Podcasts.resolve({:episode, one.id})

      # 250 seconds of 128 kbps is 4,000,000 bytes, and the audio starts at 0.
      assert playable.headers == [{"range", "bytes=4000000-"}]
      assert playable.position_ms == 250_000
    end

    test "the length and the duration of the feed decide nothing" do
      stub_audio()
      created = show()
      # Numbers that would give a wildly different offset if this read them.
      one = episode(created, %{byte_length: 99, duration_ms: 99})
      {:ok, one} = Podcast.store_position(one, %{position_ms: 250_000})

      assert {:ok, playable} = Podcasts.resolve({:episode, one.id})
      assert playable.headers == [{"range", "bytes=4000000-"}]
    end

    test "an episode whose bitrate cannot be read starts at the beginning" do
      Req.Test.stub(Mp3, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
      created = show()
      one = episode(created)
      {:ok, one} = Podcast.store_position(one, %{position_ms: 250_000})

      assert {:ok, playable} = Podcasts.resolve({:episode, one.id})

      # Repeating some audio is better than stepping over some.
      assert playable.headers == []
      assert playable.position_ms == 0
    end

    test "an episode at the start reads no audio" do
      Req.Test.stub(Mp3, fn _conn -> raise "a first play must ask for no bitrate" end)
      created = show()
      one = episode(created)

      assert {:ok, playable} = Podcasts.resolve({:episode, one.id})
      assert playable.headers == []
    end

    test "an AAC episode plays, and it reads no MP3 frame" do
      Req.Test.stub(Mp3, fn _conn -> raise "AAC holds no MP3 frame" end)
      created = show()
      one = episode(created, %{mime_type: "audio/aac"})
      {:ok, one} = Podcast.store_position(one, %{position_ms: 250_000})

      assert {:ok, playable} = Podcasts.resolve({:episode, one.id})
      assert playable.format == :aac
      assert playable.headers == []
    end

    test "an m4a episode names the reason that it cannot play" do
      created = show()
      one = episode(created, %{mime_type: "audio/x-m4a"})

      assert {:error, {:unsupported_format, "audio/x-m4a"}} =
               Podcasts.resolve({:episode, one.id})
    end
  end

  describe "the subscription" do
    test "the mark on a show subscribes to it, and it removes that" do
      created = show()

      assert :ok = Podcasts.favourite({:show, created.id}, true)
      assert [%{id: id}] = Podcast.subscribed_shows!()
      assert id == created.id

      assert :ok = Podcasts.favourite({:show, created.id}, false)
      assert [] == Podcast.subscribed_shows!()
    end

    test "an episode carries no mark" do
      created = show()
      one = episode(created)

      assert {:error, {:not_a_show, {:episode, _id}}} =
               Podcasts.favourite({:episode, one.id}, true)
    end
  end

  describe "the place inside an episode" do
    test "it writes the place of an episode" do
      created = show()
      one = episode(created)

      assert :ok = Podcasts.store_position({:episode, one.id}, 90_000)

      assert {:ok, %{position_ms: 90_000}} = Podcast.get_episode(one.id)
    end

    test "a ref that names no episode does nothing and gives ok" do
      assert :ok = Podcasts.store_position(:root, 90_000)
    end
  end

  describe "the name of a ref" do
    test "an episode holds a name, and it reads back" do
      created = show()
      one = episode(created)

      assert {:ok, name} = Podcasts.ref_to_string({:episode, one.id})
      assert name == "episode:" <> one.id
      assert {:ok, {:episode, id}} = Podcasts.ref_from_string(name)
      assert id == one.id
    end

    test "a container holds no name, because the player stores the tracks" do
      assert {:error, :cannot_name} = Podcasts.ref_to_string({:show, Ash.UUID.generate()})
      assert {:error, :cannot_name} = Podcasts.ref_to_string(:root)
    end

    test "a name that this source does not know gives an error" do
      assert {:error, :not_a_name} = Podcasts.ref_from_string("station:abc")
      assert {:error, :not_a_name} = Podcasts.ref_from_string("episode:not-a-uuid")
      assert {:error, :not_a_name} = Podcasts.ref_from_string("episode:")
    end
  end

  describe "pages" do
    test "a long list gives a cursor, and the cursor gives the rest" do
      created = show()
      for number <- 1..5, do: episode(created, %{guid: "episode-#{number}"})

      assert {:ok, %{entries: first, cursor: 2}} = Podcasts.browse({:show, created.id}, limit: 2)
      assert length(first) == 2

      assert {:ok, %{entries: last, cursor: nil}} =
               Podcasts.browse({:show, created.id}, limit: 3, cursor: 2)

      assert length(last) == 3
    end
  end
end
