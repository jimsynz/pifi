defmodule MyHiFiWeb.BrowseLiveTest do
  use MyHiFiWeb.ConnCase, async: false
  use Oban.Testing, repo: MyHiFi.Repo

  alias MyHiFi.Event
  alias MyHiFi.Event.Player, as: Events
  alias MyHiFi.Jellyfin.Fill, as: JellyfinFill
  alias MyHiFi.Playback
  alias MyHiFi.Podcast
  alias MyHiFi.Podcast.Fill, as: PodcastFill
  alias MyHiFi.Test.PlayingPipeline
  alias MyHiFi.Test.Stations

  # `render_async/1` waits `:assert_receive_timeout`, which is 100 ms, and `mix check`
  # runs the suite beside credo and ex_doc. A read of a list on a machine under that
  # load takes longer than that.
  @async_wait :timer.seconds(5)

  @jellyfin "/browse/jellyfin"
  @radio "/browse/internet-radio"
  @podcasts "/browse/podcasts"

  setup do
    # `MyHiFi.Player` is one process for the whole node, so its state outlives a test.
    MyHiFi.Player.stop()
    on_exit(fn -> MyHiFi.Player.stop() end)
    :ok
  end

  defp open(view, name), do: view |> element("#entries button", name) |> render_click()

  # A render after the event, because a message of one process arrives in order: the
  # page has read the event by the time that it answers.
  defp changed(view) do
    Event.publish(:source, %Event.Source.Changed{source: MyHiFi.Source.Podcasts, ref: :show})
    render(view)
  end

  # **Cinder reads its query in a task, so this waits for the count and it does not
  # sleep for a period.** `mix check` runs the suite beside every other tool, and a
  # fixed sleep on a machine under that load measures the load and not the firmware.
  defp read_happened?(counter, attempts \\ 100) do
    eventually(fn -> :counters.get(counter, 1) > 0 end, attempts)
  end

  defp standby(view, entered?) do
    Event.publish(:player, %Events.Standby{entered?: entered?})
    render(view)
  end

  # It counts the reads of the table that holds the rows of a list, and it gives the
  # counter to the caller so that a wait can watch it. Oban reads a table of its own
  # while this runs, and no read of that one belongs to a list.
  defp reads(fun) do
    counter = :counters.new(1, [])
    handler = "reads-#{:erlang.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:my_hi_fi, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if metadata[:source] == "playback_items", do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      fun.(counter)
    after
      :telemetry.detach(handler)
    end

    :counters.get(counter, 1)
  end

  defp eventually(check, attempts) when attempts > 0 do
    if check.() do
      true
    else
      Process.sleep(20)
      eventually(check, attempts - 1)
    end
  end

  defp eventually(_check, _attempts), do: false

  defp show(overrides \\ %{}) do
    PodcastFill.show(
      Map.merge(%{feed_url: "https://example.test/rss", title: "Road Work"}, overrides)
    )
  end

  # The source finds the feed of a show through the row that names it, so a test of the
  # control that reads a feed again needs both the item and the row.
  defp subscribed_show do
    item = show()
    {:ok, item} = Playback.set_favourite(item)
    row = Podcast.upsert_show_from_feed!(%{feed_url: "https://example.test/rss"})
    {:ok, _row} = Podcast.set_show_item(row, %{item_id: item.id})

    item
  end

  defp episode(show, overrides \\ %{}) do
    attributes =
      Map.merge(
        %{
          guid: "episode-#{System.unique_integer([:positive])}",
          title: "An episode",
          audio_url: "https://example.test/1.mp3",
          mime_type: "audio/mpeg",
          duration_ms: 600_000,
          published_at: ~U[2022-06-02 14:00:00.000000Z],
          description: nil,
          artwork_url: nil
        },
        overrides
      )

    PodcastFill.episodes(show, "https://example.test/rss", [attributes])

    Enum.find(
      Playback.items_of_parent!(show.id),
      &(&1.source_ref == PodcastFill.episode_ref("https://example.test/rss", attributes.guid))
    )
  end

  defp jellyfin_album do
    JellyfinFill.artists([
      %{ref: "artist-1", title: "Massive Attack", parent_ref: nil, artwork_url: nil}
    ])

    JellyfinFill.albums([
      %{
        ref: "album-1",
        title: "Mezzanine",
        parent_ref: "artist-1",
        artwork_url: nil,
        subtitle: "Massive Attack",
        release_year: 1998
      }
    ])

    Enum.find(Playback.list_items!(), &(&1.source_ref == "album-1"))
  end

  describe "the branches of a source" do
    test "the page draws what the source names, in that order", %{conn: conn} do
      {:ok, _view, html} = live(conn, @radio)

      assert html =~ "Favourites"
      assert html =~ "Countries"
      assert html =~ "Tags"
    end

    test "another source names its own branches", %{conn: conn} do
      {:ok, _view, html} = live(conn, @podcasts)

      assert html =~ "Subscriptions"
      assert html =~ "Trending"
    end

    test "an album row shows its release year", %{conn: conn} do
      album = jellyfin_album()
      {:ok, view, _html} = live(conn, "#{@jellyfin}/albums")

      render_async(view, @async_wait)

      assert has_element?(view, "#open-#{album.id}", "1998")
    end

    test "an address that names no source goes to the first one", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/browse/nonsense")
      assert to == @radio
    end
  end

  # A row of a facet opens into the items that link to it. The page holds no knowledge
  # of a country, and internet radio takes no part in the read.
  describe "a facet opens into the items that hold it" do
    test "a country lists its stations", %{conn: conn} do
      Stations.create(%{country_code: "NZ", title: "RNZ National"})
      Stations.create(%{country_code: "AU", title: "ABC Sydney"})

      {:ok, view, _html} = live(conn, @radio)
      html = open(view, "Countries")

      assert html =~ "NZ"
      assert html =~ "AU"

      html = view |> element("button", "NZ") |> render_click()

      assert html =~ "RNZ National"
      refute html =~ "ABC Sydney"
    end

    test "a tag lists its stations", %{conn: conn} do
      Stations.create(%{tags: ["news"], title: "A news station"})

      {:ok, view, _html} = live(conn, @radio)
      open(view, "Tags")
      html = view |> element("button", "news") |> render_click()

      assert html =~ "A news station"
    end

    # The service counts how many people listen, and `rank` holds that. A person who
    # opens a country reads the best known station first.
    test "the best known station of a country comes first", %{conn: conn} do
      # The titles must disagree with the ranks, or the test passes on the alphabet.
      Stations.create(%{country_code: "NZ", title: "Alpha, hardly anybody", click_count: 3})
      Stations.create(%{country_code: "NZ", title: "Zulu, everybody knows it", click_count: 900})

      {:ok, view, _html} = live(conn, @radio)
      open(view, "Countries")
      html = view |> element("button", "NZ") |> render_click()

      assert index_of(html, "Zulu, everybody knows it") < index_of(html, "Alpha, hardly anybody")
    end

    test "a country of another source is not in the list", %{conn: conn} do
      Stations.create(%{country_code: "NZ"})
      marked = show()
      {:ok, _marked} = Playback.set_favourite(marked)

      {:ok, view, _html} = live(conn, @podcasts)
      open(view, "Subscriptions")

      # `NZ` is two letters, and the page holds a signed token of the player that holds
      # random base64. That token gave `NZ` about one run in twenty, and this test then
      # failed for no reason of its own. The list is what the test is about.
      html = view |> element("#browse") |> render()

      assert html =~ "Road Work"
      refute html =~ "NZ"
    end
  end

  # An item of the kind `:container` opens into the items whose `parent_id` names it.
  describe "a container opens into what it holds" do
    test "a show lists its episodes", %{conn: conn} do
      created = show()
      {:ok, created} = Playback.set_favourite(created)
      episode(created, %{title: "The first one"})

      {:ok, view, _html} = live(conn, @podcasts)
      open(view, "Subscriptions")
      html = view |> element("button", "Road Work") |> render_click()

      assert html =~ "The first one"
    end

    # A person who presses one episode queues the rest of the list behind it, so the
    # order of the list is the order that they hear.
    # **The newest episode comes first**, because a person who opens a show wants the
    # episode of this week. The source says so, and the sort control of the page flips
    # it for a person who starts a series from the start. See
    # `c:MyHiFi.Source.listing/1`.
    test "the newest episode comes first", %{conn: conn} do
      created = show()
      {:ok, created} = Playback.set_favourite(created)
      episode(created, %{title: "The older one", published_at: ~U[2022-06-01 14:00:00Z]})
      episode(created, %{title: "The newer one", published_at: ~U[2024-06-01 14:00:00Z]})

      {:ok, view, _html} = live(conn, @podcasts)
      open(view, "Subscriptions")
      html = view |> element("button", "Road Work") |> render_click()

      assert index_of(html, "The newer one") < index_of(html, "The older one")
    end

    test "the date of an episode is in the row", %{conn: conn} do
      created = show()
      {:ok, created} = Playback.set_favourite(created)
      episode(created, %{title: "The first one", published_at: ~U[2022-06-01 14:00:00Z]})

      {:ok, view, _html} = live(conn, @podcasts)
      open(view, "Subscriptions")
      html = view |> element("button", "Road Work") |> render_click()

      assert html =~ "1 June 2022"
    end

    # A publisher that names a number gets one in front of the title, and one that names
    # none gets no place at all.
    test "the number of an episode is in the row", %{conn: conn} do
      created = show()
      {:ok, created} = Playback.set_favourite(created)
      episode(created, %{title: "The numbered one", number: 639})

      {:ok, view, _html} = live(conn, @podcasts)
      open(view, "Subscriptions")
      html = view |> element("button", "Road Work") |> render_click()

      assert html =~ "639"
    end

    # A person reads this to decide whether they have time for the rest of an episode.
    test "an episode that a person began says how much is left", %{conn: conn} do
      created = show()
      {:ok, created} = Playback.set_favourite(created)
      one = episode(created, %{title: "The long one", duration_ms: 3_600_000})
      {:ok, _one} = Playback.store_position(one, %{position_ms: 960_000})

      {:ok, view, _html} = live(conn, @podcasts)
      open(view, "Subscriptions")
      html = view |> element("button", "Road Work") |> render_click()

      assert html =~ "44m left"
    end

    test "a container that holds nothing says so", %{conn: conn} do
      created = show()
      {:ok, _created} = Playback.set_favourite(created)

      {:ok, view, _html} = live(conn, @podcasts)
      open(view, "Subscriptions")
      html = view |> element("button", "Road Work") |> render_click()

      assert html =~ "Nothing here."
    end
  end

  describe "the breadcrumbs" do
    test "each level adds one, and a press goes back to it", %{conn: conn} do
      Stations.create(%{country_code: "NZ", title: "RNZ National"})

      {:ok, view, _html} = live(conn, @radio)
      open(view, "Countries")
      html = view |> element("button", "NZ") |> render_click()

      assert html =~ "Countries"
      assert html =~ "RNZ National"

      html = view |> element("#crumb-1") |> render_click()

      assert html =~ "NZ"
      refute html =~ "RNZ National"
    end

    test "the name of the source goes back to the branches", %{conn: conn} do
      {:ok, view, _html} = live(conn, @radio)
      open(view, "Countries")

      html = view |> element("#crumb-0") |> render_click()

      assert html =~ "Favourites"
      assert html =~ "Tags"
    end
  end

  describe "playing a track" do
    test "a track that plays marks its row", %{conn: conn} do
      PlayingPipeline.use_it()
      station = Stations.create(%{country_code: "NZ", title: "RNZ National"})

      {:ok, view, _html} = live(conn, @radio)
      open(view, "Countries")
      view |> element("button", "NZ") |> render_click()

      html = view |> element("#play-#{station.id}") |> render_click()

      assert html =~ "Playing RNZ National."
      assert has_element?(view, ~s(#play-#{station.id}[aria-current="true"]))
    end

    test "a track that cannot play shows the reason", %{conn: conn} do
      created = show()
      {:ok, created} = Playback.set_favourite(created)
      one = episode(created, %{mime_type: "audio/x-m4a"})

      {:ok, view, _html} = live(conn, @podcasts)
      open(view, "Subscriptions")
      view |> element("button", "Road Work") |> render_click()

      html = view |> element("#play-#{one.id}") |> render_click()

      assert html =~ "Could not play that"
    end

    test "a stop takes the marker off", %{conn: conn} do
      PlayingPipeline.use_it()
      station = Stations.create(%{country_code: "NZ"})

      {:ok, view, _html} = live(conn, @radio)
      open(view, "Countries")
      view |> element("button", "NZ") |> render_click()
      view |> element("#play-#{station.id}") |> render_click()

      Event.publish(:player, %Events.Stopped{reason: :requested})

      refute has_element?(view, ~s(#play-#{station.id}[aria-current="true"]))
    end
  end

  describe "the mark on the head of a collection" do
    # **A person who opened an album and liked what they read marks it there**, and they
    # do not walk back up the tree to reach the row that names it.
    test "a show takes a mark while a person is inside it", %{conn: conn} do
      created = show()
      {:ok, created} = Playback.set_favourite(created)
      other = show(%{feed_url: "https://example.test/other", title: "Night Shift"})

      {:ok, view, _html} = live(conn, @podcasts)
      open(view, "Subscriptions")
      view |> element("button", "Road Work") |> render_click()

      refute Playback.get_item!(other.id).favourite?

      {:ok, view, _html} = live(conn, "#{@podcasts}/#{other.id}")

      assert has_element?(view, "#favourite-#{other.id}[aria-pressed='false']")

      view |> element("#favourite-#{other.id}") |> render_click()

      # The head of the collection draws the star that the person pressed, and the read
      # of the item says that the mark reached the card.
      assert has_element?(view, "#favourite-#{other.id}[aria-pressed='true']")
      assert Playback.get_item!(other.id).favourite?
    end

    test "the mark comes off the same way", %{conn: conn} do
      created = show()
      {:ok, created} = Playback.set_favourite(created)

      {:ok, view, _html} = live(conn, "#{@podcasts}/#{created.id}")

      assert has_element?(view, "#favourite-#{created.id}[aria-pressed='true']")

      view |> element("#favourite-#{created.id}") |> render_click()

      assert has_element?(view, "#favourite-#{created.id}[aria-pressed='false']")
      refute Playback.get_item!(created.id).favourite?
    end

    # An episode belongs to a show, and a person marks the show.
    test "an episode of a show draws no mark of its own", %{conn: conn} do
      created = show()
      {:ok, created} = Playback.set_favourite(created)
      one = episode(created, %{title: "The first one"})

      {:ok, view, _html} = live(conn, "#{@podcasts}/#{created.id}")

      refute has_element?(view, "#favourite-#{one.id}")
    end
  end

  describe "the mark of a person" do
    test "a station takes a mark, and gives it back", %{conn: conn} do
      station = Stations.create(%{country_code: "NZ"})

      {:ok, view, _html} = live(conn, @radio)
      open(view, "Countries")
      view |> element("button", "NZ") |> render_click()

      view |> element("#favourite-#{station.id}") |> render_click()
      assert [%{id: id}] = Playback.favourite_items!()
      assert id == station.id

      view |> element("#favourite-#{station.id}") |> render_click()
      assert Playback.favourite_items!() == []
    end

    # A person subscribes to the show, and an episode carries no mark of its own.
    test "an episode holds no control", %{conn: conn} do
      created = show()
      {:ok, created} = Playback.set_favourite(created)
      one = episode(created)

      {:ok, view, _html} = live(conn, @podcasts)
      open(view, "Subscriptions")
      view |> element("button", "Road Work") |> render_click()

      assert has_element?(view, "#play-#{one.id}")
      refute has_element?(view, "#favourite-#{one.id}")
    end

    test "a show takes a mark, which is the subscription", %{conn: conn} do
      created = show()
      {:ok, _created} = Playback.set_favourite(created)

      {:ok, view, _html} = live(conn, @podcasts)
      open(view, "Subscriptions")

      assert has_element?(view, "#favourite-#{created.id}")
    end
  end

  describe "the played mark" do
    # A person hears an episode over several days, so an episode is the kind of track
    # that a person leaves unfinished and then wants to say that they are done with.
    test "an episode takes the mark, and gives it back", %{conn: conn} do
      created = show()
      {:ok, created} = Playback.set_favourite(created)
      one = episode(created, %{title: "The first one"})

      {:ok, view, _html} = live(conn, @podcasts)
      open(view, "Subscriptions")
      view |> element("button", "Road Work") |> render_click()

      assert has_element?(view, "#played-#{one.id}[aria-pressed='false']")

      view |> element("#played-#{one.id}") |> render_click()
      assert Playback.get_item!(one.id).played?

      view |> element("#played-#{one.id}") |> render_click()
      refute Playback.get_item!(one.id).played?
    end

    # A station holds no place, so a person is never in the middle of one.
    test "a station holds no control", %{conn: conn} do
      station = Stations.create(%{country_code: "NZ"})

      {:ok, view, _html} = live(conn, @radio)
      open(view, "Countries")
      view |> element("button", "NZ") |> render_click()

      assert has_element?(view, "#play-#{station.id}")
      refute has_element?(view, "#played-#{station.id}")
    end
  end

  # A source reads a service behind the page, so what a container holds can change
  # while a person looks at it.
  test "the page reads the list again when a source says that it changed", %{conn: conn} do
    created = show()
    {:ok, created} = Playback.set_favourite(created)

    {:ok, view, _html} = live(conn, @podcasts)
    open(view, "Subscriptions")
    html = view |> element("button", "Road Work") |> render_click()
    assert html =~ "Nothing here."

    episode(created, %{title: "It arrived"})
    Event.publish(:source, %Event.Source.Changed{source: MyHiFi.Source.Podcasts, ref: :show})

    # Cinder reads the query in a task, so the render that follows the event is not the
    # one that holds the answer.
    assert render_async(view, @async_wait) =~ "It arrived"
  end

  describe "a device in standby" do
    # **The layout of a device in standby draws no list, so a read then reaches no
    # person.** A render therefore cannot say whether the read happened, and this counts
    # what the Repo did instead. The first count is the control: it says that the
    # measurement measures something.
    test "it holds the read of a list until the device wakes", %{conn: conn} do
      created = show()
      {:ok, created} = Playback.set_favourite(created)

      {:ok, view, _html} = live(conn, @podcasts)
      open(view, "Subscriptions")
      assert view |> element("button", "Road Work") |> render_click() =~ "Nothing here."

      episode(created, %{title: "It arrived"})

      # The control of the measurement: a page of a device that is awake reads the list
      # again, so the count moves and the count means something.
      assert reads(fn counter ->
               changed(view)
               read_happened?(counter)
             end) > 0

      assert render_async(view, @async_wait) =~ "It arrived"

      standby(view, true)
      episode(created, %{title: "And another"})

      # Half a second is longer than the read of the control above, and the count stays
      # at nothing.
      assert reads(fn counter ->
               changed(view)
               read_happened?(counter, 25)
             end) == 0

      standby(view, false)

      assert render_async(view, @async_wait) =~ "And another"
    end

    # `MyHiFiWeb.BrowseLive` draws no collection while it says that this firmware holds
    # no source, so it holds no identifier for one either.
    test "a page that draws no list stays alive when a source changes", %{conn: conn} do
      # A firmware with every source out of use is what draws that page, and
      # `MyHiFi.Source.chosen/0` gives the first source in use for every other state.
      for module <- MyHiFi.Source.all(), do: MyHiFi.Source.enable(module, false)

      {:ok, view, html} = live(conn, "/")

      assert html =~ "This firmware holds no source"

      changed(view)

      assert render(view) =~ "This firmware holds no source"
    end
  end

  # The filters and the sort take the room of three rows, and a person wants them for a
  # long list alone.
  describe "the control that brings the filters and the sort" do
    # **The sort shows for a list whose source names an order**, because a person who
    # opens a show wants the newest episode and a person who reads a series wants the
    # oldest, and one press must be enough. The filter still waits to be asked for.
    test "a list starts with the sort and without the filter", %{conn: conn} do
      Stations.create(%{country_code: "NZ", title: "RNZ National"})

      {:ok, _view, html} = live(conn, "#{@radio}/countries/NZ")

      refute html =~ "Filter Title..."
      assert html =~ "toggle_sort"
      assert html =~ "RNZ National"
    end

    test "the control brings them, and it takes them away", %{conn: conn} do
      Stations.create(%{country_code: "NZ", title: "RNZ National"})

      {:ok, view, _html} = live(conn, "#{@radio}/countries/NZ")

      assert view |> element("#find") |> render_click() =~ "Filter Title..."
      assert_patched(view, "#{@radio}/countries/NZ?find=1")

      refute view |> element("#find") |> render_click() =~ "Filter Title..."
      assert_patched(view, "#{@radio}/countries/NZ")
    end

    # A person who opens the controls keeps them through a level change, because it is
    # what they chose and not a part of the level.
    test "the mark stays through a level change", %{conn: conn} do
      Stations.create(%{country_code: "NZ", title: "RNZ National"})

      {:ok, view, _html} = live(conn, "#{@radio}/countries/NZ?find=1")

      view |> element("#crumb-1") |> render_click()

      assert_patched(view, "#{@radio}/countries?find=1")
      assert render(view) =~ "Filter Countries..."
    end

    # The branches are not a collection, so there is nothing to filter and nothing to
    # sort.
    test "the branches hold no such control", %{conn: conn} do
      {:ok, _view, html} = live(conn, @radio)

      refute html =~ ~s(id="find")
    end

    # Cinder asks for `contains` with an `Ash.CiString`, and that compiles to
    # `instr(title, ? COLLATE NOCASE)`. `instr` of SQLite reads no collation, so a
    # person who typed `rnz` found no `RNZ National`. See
    # `MyHiFiWeb.ItemList.filter_title/2`.
    test "the case of the filter does not matter", %{conn: conn} do
      Stations.create(%{country_code: "NZ", title: "RNZ National"})

      for text <- ["rnz", "RNZ", "Rnz", "national"] do
        {:ok, _view, html} = live(conn, "#{@radio}/countries/NZ?sorted_title=#{text}")

        assert html =~ "RNZ National", "#{text} found nothing"
      end
    end

    # SQLite compares text byte by byte, so every capital letter comes in front of
    # every small one. A station whose name begins with a small letter therefore read
    # after every Z. See `MyHiFi.Playback.Item`.
    test "a sort of the title reads the letters and not the bytes", %{conn: conn} do
      Stations.create(%{country_code: "NZ", title: "Zulu FM"})
      Stations.create(%{country_code: "NZ", title: "alt-J Radio"})

      {:ok, _view, html} = live(conn, "#{@radio}/countries/NZ?sort=sorted_title")

      assert index_of(html, "alt-J Radio") < index_of(html, "Zulu FM")
    end
  end

  defp index_of(html, text) do
    [start, _rest] = String.split(html, text, parts: 2)
    String.length(start)
  end

  # A person who knows the name of a station or of a show does not want to walk a tree
  # for it.
  # A source says whether it reads a service again, and this page draws the control from
  # that answer alone. See `MyHiFi.Source.refresh/2`.
  describe "the control that reads a source again" do
    test "a show holds it", %{conn: conn} do
      created = subscribed_show()
      episode(created, %{title: "The first one"})

      {:ok, view, _html} = live(conn, @podcasts)
      open(view, "Subscriptions")
      html = view |> element("button", "Road Work") |> render_click()

      assert html =~ ~s(id="refresh")
    end

    # A branch is a list that the page makes, and no source reads it again.
    test "a branch of the same source holds none", %{conn: conn} do
      subscribed_show()

      {:ok, view, _html} = live(conn, @podcasts)
      html = open(view, "Subscriptions")

      refute html =~ ~s(id="refresh")
    end

    # Internet radio reads a whole country, and the settings page holds that control.
    test "a source that reads no container again holds none", %{conn: conn} do
      Stations.create(%{country_code: "NZ", title: "RNZ National"})

      {:ok, view, _html} = live(conn, @radio)
      html = open(view, "Countries")

      refute html =~ ~s(id="refresh")
    end

    test "it asks the source, and it tells the person", %{conn: conn} do
      created = subscribed_show()
      episode(created, %{title: "The first one"})

      {:ok, view, _html} = live(conn, @podcasts)
      open(view, "Subscriptions")
      view |> element("button", "Road Work") |> render_click()

      # The read of the feed goes to a job, because it holds the network and a person
      # is waiting. `MyHiFi.Event.Source.Changed` brings the newer episodes.
      refute_enqueued(worker: MyHiFi.Podcast.Show.Workers.Refresh)

      html = view |> element("#refresh") |> render_click()

      assert html =~ "The device reads this again now."
      assert_enqueued(worker: MyHiFi.Podcast.Show.Workers.Refresh)
    end
  end

  describe "the control that finds by name" do
    test "the branches hold it", %{conn: conn} do
      {:ok, view, _html} = live(conn, @radio)

      assert has_element?(view, "#finder")
    end

    test "a level below the branches holds no such control", %{conn: conn} do
      Stations.create(%{country_code: "NZ"})

      {:ok, view, _html} = live(conn, "#{@radio}/countries")

      refute has_element?(view, "#finder")
    end

    test "a name gives the page that finds it", %{conn: conn} do
      {:ok, view, _html} = live(conn, @radio)

      {:error, {:live_redirect, %{to: to}}} =
        view |> form("#finder", %{"text" => "newstalk"}) |> render_submit()

      assert to == "#{@radio |> String.replace("/browse/", "/search/")}?search=newstalk"
    end

    test "an empty name goes nowhere", %{conn: conn} do
      {:ok, view, _html} = live(conn, @radio)

      assert view |> form("#finder", %{"text" => "   "}) |> render_submit() =~ "Favourites"
    end
  end

  # This is the point of the queue: a person presses one track of a list, and next and
  # previous then move through the list that they were looking at.
  describe "the list that a person sees goes in the queue" do
    test "pressing a track queues the whole list, and marks the row", %{conn: conn} do
      Stations.create(%{country_code: "NZ", title: "Alpha", click_count: 3})
      Stations.create(%{country_code: "NZ", title: "Bravo", click_count: 2})
      Stations.create(%{country_code: "NZ", title: "Charlie", click_count: 1})

      {:ok, view, _html} = live(conn, "#{@radio}/countries/NZ")
      [_alpha, bravo, _charlie] = Playback.items_of_source!("internet-radio")

      view |> element("#play-#{bravo.id}") |> render_click()

      titles =
        Playback.queue!() |> Enum.map(&Playback.get_item!(&1.item_id).title)

      assert titles == ["Alpha", "Bravo", "Charlie"]
      assert %{item_id: id} = Playback.queue_playing!()
      assert id == bravo.id
    end

    # A filter is what a person chose to look at, so the queue holds that and not the
    # whole country.
    test "a filtered list queues what the filter left", %{conn: conn} do
      Stations.create(%{country_code: "NZ", title: "Alpha"})
      Stations.create(%{country_code: "NZ", title: "Bravo"})

      {:ok, view, _html} = live(conn, "#{@radio}/countries/NZ?find=1&sorted_title=Alpha")
      [alpha, _bravo] = Playback.items_of_source!("internet-radio")

      view |> element("#play-#{alpha.id}") |> render_click()

      assert [%{item_id: id}] = Playback.queue!()
      assert id == alpha.id
    end

    # A show is a container, and a container never plays, so it must not reach the
    # queue beside the episodes of a search.
    test "a container of the list stays out of the queue", %{conn: conn} do
      created = show()
      {:ok, created} = Playback.set_favourite(created)
      one = episode(created, %{title: "The first one"})

      {:ok, view, _html} = live(conn, "#{@podcasts}/subscriptions/#{created.id}")

      view |> element("#play-#{one.id}") |> render_click()

      assert [%{item_id: id}] = Playback.queue!()
      assert id == one.id
    end
  end

  # The number says whether a row is worth opening.
  describe "the badge of a container" do
    test "a facet says how many items hold it", %{conn: conn} do
      Stations.create(%{country_code: "NZ", title: "One"})
      Stations.create(%{country_code: "NZ", title: "Two"})
      Stations.create(%{country_code: "AU", title: "Three"})

      {:ok, view, _html} = live(conn, @radio)
      html = open(view, "Countries")

      assert html =~ ~r/NZ.*?>\s*2\s*</s
      assert html =~ ~r/AU.*?>\s*1\s*</s
    end

    test "a show says how many episodes it holds", %{conn: conn} do
      created = show()
      {:ok, created} = Playback.set_favourite(created)
      episode(created, %{title: "The first one"})
      episode(created, %{title: "The second one"})

      {:ok, view, _html} = live(conn, @podcasts)
      html = open(view, "Subscriptions")

      assert html =~ ~r/Road Work.*?>\s*2\s*</s
    end

    # 0 is a thing that a person reads and then acts on, and there is nothing to act on.
    test "a branch says how many rows it holds", %{conn: conn} do
      Stations.create(%{country_code: "NZ", tags: ["news"], title: "One"})
      Stations.create(%{country_code: "AU", tags: ["talk", "sport"], title: "Two"})

      {:ok, _view, html} = live(conn, @radio)

      # Two countries, and three tags.
      assert html =~ ~r/Countries.*?>\s*2\s*</s
      assert html =~ ~r/Tags.*?>\s*3\s*</s
    end

    test "a branch that holds nothing shows no badge", %{conn: conn} do
      {:ok, _view, html} = live(conn, @radio)

      assert html =~ "Favourites"
      refute html =~ ~r/Favourites.*?>\s*0\s*</s
    end

    test "a show that holds no episode shows no badge", %{conn: conn} do
      created = show()
      {:ok, _created} = Playback.set_favourite(created)

      {:ok, view, _html} = live(conn, @podcasts)
      html = open(view, "Subscriptions")

      assert html =~ "Road Work"
      refute html =~ ~r/Road Work.*?>\s*0\s*</s
    end
  end

  # A person who opens a country can send that address to somebody, and a reload gives
  # the same list back.
  # The top row of the faceplate is the source switch of this device, and a switch stays
  # where a hand put it. See `MyHiFi.Source.chosen/0`.
  describe "the source switch" do
    setup do
      on_exit(fn ->
        case MyHiFi.Settings.fetch(MyHiFi.Source.chosen_key()) do
          {:ok, setting} -> MyHiFi.Settings.delete!(setting)
          {:error, _reason} -> :ok
        end
      end)

      :ok
    end

    test "a device that no person has used opens the first source in use", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: @radio}}} = live(conn, ~p"/")
    end

    test "an address with no source opens the source that a person chose", %{conn: conn} do
      {:ok, _view, _html} = live(conn, @podcasts)

      assert {:error, {:live_redirect, %{to: @podcasts}}} = live(conn, ~p"/")
    end

    test "a search of a source moves the switch as well", %{conn: conn} do
      {:ok, _view, _html} = live(conn, ~p"/search/podcasts")

      assert MyHiFi.Source.chosen() == MyHiFi.Source.Podcasts
    end

    # A person who took the chosen source out of use must still find a page.
    test "a source that goes out of use gives the first source in use", %{conn: conn} do
      {:ok, _view, _html} = live(conn, @podcasts)
      MyHiFi.Source.enable(MyHiFi.Source.Podcasts, false)
      on_exit(fn -> MyHiFi.Source.enable(MyHiFi.Source.Podcasts, true) end)

      assert {:error, {:live_redirect, %{to: @radio}}} = live(conn, ~p"/")
    end
  end

  describe "the address" do
    test "opening a branch and a facet writes each level into it", %{conn: conn} do
      Stations.create(%{country_code: "NZ", title: "RNZ National"})

      {:ok, view, _html} = live(conn, @radio)

      open(view, "Countries")
      assert_patched(view, "#{@radio}/countries")

      view |> element("button", "NZ") |> render_click()
      assert_patched(view, "#{@radio}/countries/NZ")
    end

    test "an address of a facet gives that list at once", %{conn: conn} do
      Stations.create(%{country_code: "NZ", title: "RNZ National"})
      Stations.create(%{country_code: "AU", title: "ABC Sydney"})

      {:ok, _view, html} = live(conn, "#{@radio}/countries/NZ")

      assert html =~ "RNZ National"
      refute html =~ "ABC Sydney"
      # The breadcrumbs come back with it.
      assert html =~ "Countries"
    end

    test "an address of a show gives its episodes at once", %{conn: conn} do
      created = show()
      {:ok, created} = Playback.set_favourite(created)
      episode(created, %{title: "The first one"})

      {:ok, _view, html} = live(conn, "#{@podcasts}/subscriptions/#{created.id}")

      assert html =~ "The first one"
      assert html =~ "Road Work"
    end

    # Each level is a collection of its own. Cinder keeps the sort of a collection, and
    # a level of facets and a level of items are two resources, so one identifier for
    # both gives the sort of an item list to a query of facets and the read stops.
    test "a crumb takes the level off the address, and that list draws", %{conn: conn} do
      Stations.create(%{country_code: "NZ", title: "RNZ National"})

      {:ok, view, _html} = live(conn, "#{@radio}/countries/NZ")

      view |> element("#crumb-1") |> render_click()
      assert_patched(view, "#{@radio}/countries")
      assert render(view) =~ "NZ"

      view |> element("#crumb-0") |> render_click()
      assert_patched(view, "#{@radio}")
      assert render(view) =~ "Countries"
    end

    # A show that a job removed, or a country that lost its last station, leaves an
    # address behind. A person gets the level that still stands.
    test "an address that names nothing gives the level above it", %{conn: conn} do
      {:ok, _view, html} = live(conn, "#{@podcasts}/subscriptions/#{Ash.UUID.generate()}")

      assert html =~ "Nothing here."
      assert html =~ "Subscriptions"
    end

    test "an address that names no branch gives the branches", %{conn: conn} do
      {:ok, _view, html} = live(conn, "#{@radio}/nonsense")

      assert html =~ "Favourites"
      assert html =~ "Countries"
    end

    test "a sort goes into the address, and a reload holds it", %{conn: conn} do
      Stations.create(%{country_code: "NZ", title: "Alpha FM"})
      Stations.create(%{country_code: "NZ", title: "Zulu FM"})

      {:ok, view, _html} = live(conn, "#{@radio}/countries/NZ?find=1")

      view
      |> element("button[phx-click='toggle_sort'][phx-value-key='sorted_title']")
      |> render_click()

      # A country list holds two sorts: the popularity that the level asked for, and
      # the title that a person pressed.
      assert assert_patch(view) == "#{@radio}/countries/NZ?find=1&sort=-rank%2C-sorted_title"

      {:ok, _reloaded, html} = live(conn, "#{@radio}/countries/NZ?sort=-sorted_title")

      assert index_of(html, "Zulu FM") < index_of(html, "Alpha FM")
    end

    # A sort belongs to the level that a person set it on. A level of facets and a level
    # of items are two resources, and a sort of one is no field of the other.
    test "a filter goes into the address, and a reload holds it", %{conn: conn} do
      Stations.create(%{country_code: "NZ", title: "Alpha FM"})
      Stations.create(%{country_code: "NZ", title: "Zulu FM"})

      {:ok, view, _html} = live(conn, "#{@radio}/countries/NZ?find=1")

      view
      |> form("#browse-countries-nz-filter-form", filters: %{sorted_title: "Zulu"})
      |> render_change()

      assert assert_patch(view) ==
               "#{@radio}/countries/NZ?find=1&sort=-rank%2Csorted_title&sorted_title=Zulu"

      {:ok, _reloaded, html} = live(conn, "#{@radio}/countries/NZ?sorted_title=Zulu")

      assert html =~ "Zulu FM"
      refute html =~ "Alpha FM"
    end

    test "a new level starts with no sort", %{conn: conn} do
      Stations.create(%{country_code: "NZ", title: "Alpha FM"})

      {:ok, view, _html} = live(conn, "#{@radio}/countries/NZ?find=1")

      view
      |> element("button[phx-click='toggle_sort'][phx-value-key='sorted_title']")
      |> render_click()

      view |> element("#crumb-1") |> render_click()

      assert_patched(view, "#{@radio}/countries?find=1")
      assert render(view) =~ "NZ"
    end

    # A search finds a show that no branch of the source holds, so the address of a
    # container cannot need a branch above it.
    test "a container is named by its identifier, with no branch", %{conn: conn} do
      created = show()
      episode(created, %{title: "The first one"})

      {:ok, _view, html} = live(conn, "#{@podcasts}/#{created.id}")

      assert html =~ "The first one"
      assert html =~ "Road Work"
    end

    test "a container of another source is not addressed under this one", %{conn: conn} do
      created = show()

      {:ok, _view, html} = live(conn, "#{@radio}/#{created.id}")

      # The walk ends, so a person gets the branches of internet radio.
      assert html =~ "Countries"
      refute html =~ "Road Work"
    end

    test "a tag that holds a space reads back from the address", %{conn: conn} do
      Stations.create(%{tags: ["classic rock"], title: "A rock station"})

      {:ok, view, _html} = live(conn, @radio)
      open(view, "Tags")
      view |> element("button", "classic rock") |> render_click()

      assert_patched(view, "#{@radio}/tags/classic%20rock")
      assert render(view) =~ "A rock station"
    end
  end

  test "a firmware with no source says so", %{conn: conn} do
    Application.put_env(:my_hi_fi, :sources, [])
    on_exit(fn -> Application.delete_env(:my_hi_fi, :sources) end)

    {:ok, _view, html} = live(conn, @radio)

    assert html =~ "This firmware holds no source."
  end

  describe "the picture of a collection" do
    defp collection_tree do
      artist =
        Playback.upsert_item!(%{
          source: "podcasts",
          source_ref: "artist-1",
          kind: :container,
          title: "An artist",
          artwork_url: "https://example.test/artist.jpg"
        })

      album =
        Playback.upsert_item!(%{
          source: "podcasts",
          source_ref: "album-1",
          kind: :container,
          parent_id: artist.id,
          title: "An album",
          description: "What the publisher wrote about it.",
          artwork_url: "https://example.test/album.jpg"
        })

      {:ok, artist} = Playback.set_favourite(artist)
      {:ok, album} = Playback.set_favourite(album)

      {artist, album}
    end

    defp with_tracks(album, count) do
      for number <- 1..count do
        Playback.upsert_item!(%{
          source: "podcasts",
          source_ref: "track-#{number}",
          kind: :track,
          parent_id: album.id,
          title: "Track #{number}",
          url: "https://example.test/#{number}.mp3",
          transport: :download,
          format: :mp3,
          keeps_place?: false
        })
      end
    end

    # The address of a picture is the hash of the address of the picture, so a row draws
    # it with no read of the cache. See `MyHiFi.Artwork.thumbnail_path/1`.
    test "a row of a container draws its picture", %{conn: conn} do
      {_artist, album} = collection_tree()
      path = MyHiFi.Artwork.thumbnail_path(album.artwork_url)

      {:ok, _view, html} = live(conn, "#{@podcasts}/subscriptions")

      assert html =~ path
    end

    # A picture that the cache does not hold answers 404, and the folder behind it stays.
    test "a row keeps a folder behind the picture", %{conn: conn} do
      collection_tree()

      {:ok, _view, html} = live(conn, "#{@podcasts}/subscriptions")

      assert html =~ "hero-folder"
      assert html =~ "data-cover"
    end
  end

  describe "the head of a collection" do
    test "it shows the name, the words and the picture of the collection", %{conn: conn} do
      {_artist, album} = collection_tree()
      with_tracks(album, 2)

      {:ok, _view, html} = live(conn, "#{@podcasts}/subscriptions/#{album.id}")

      assert html =~ "collection-header"
      assert html =~ "An album"
      assert html =~ "What the publisher wrote about it."
      assert html =~ MyHiFi.Artwork.thumbnail_path(album.artwork_url)
    end

    # A person reaches an album from the list of albums, from the favourites and from a
    # search, and no crumb of those paths names the artist.
    test "it names the collection that holds this one", %{conn: conn} do
      {_artist, album} = collection_tree()

      {:ok, view, _html} = live(conn, "#{@podcasts}/subscriptions/#{album.id}")

      assert has_element?(view, "#open-parent", "An artist")
    end

    test "a press on that name opens the collection that holds this one", %{conn: conn} do
      {artist, album} = collection_tree()

      {:ok, view, _html} = live(conn, "#{@podcasts}/subscriptions/#{album.id}")

      view |> element("#open-parent") |> render_click()

      assert_patched(view, "#{@podcasts}/#{artist.id}")
      assert has_element?(view, "#collection-header", "An artist")
    end

    # A show sits at the top of its source, so there is nothing above it to open.
    test "a collection that nothing holds names none", %{conn: conn} do
      {artist, _album} = collection_tree()

      {:ok, view, _html} = live(conn, "#{@podcasts}/subscriptions/#{artist.id}")

      refute has_element?(view, "#open-parent")
    end

    test "a collection that nothing holds shows its own words instead", %{conn: conn} do
      show =
        Playback.upsert_item!(%{
          source: "podcasts",
          source_ref: "show-1",
          kind: :container,
          title: "A show",
          subtitle: "Every week"
        })

      {:ok, _view, html} = live(conn, "#{@podcasts}/subscriptions/#{show.id}")

      assert html =~ "Every week"
    end

    test "a collection of tracks alone holds a play control", %{conn: conn} do
      {_artist, album} = collection_tree()
      with_tracks(album, 2)

      {:ok, view, _html} = live(conn, "#{@podcasts}/subscriptions/#{album.id}")

      assert has_element?(view, "#play-collection")
    end

    # A press would mean "play every track of every album of this artist", and a person
    # who opened an artist asked to read the albums.
    test "a collection that holds collections holds none", %{conn: conn} do
      {artist, _album} = collection_tree()

      {:ok, view, _html} = live(conn, "#{@podcasts}/subscriptions/#{artist.id}")

      assert has_element?(view, "#collection-header")
      refute has_element?(view, "#play-collection")
    end

    test "a collection that holds nothing holds none", %{conn: conn} do
      empty =
        Playback.upsert_item!(%{
          source: "podcasts",
          source_ref: "empty-1",
          kind: :container,
          title: "An empty album"
        })

      {:ok, view, _html} = live(conn, "#{@podcasts}/subscriptions/#{empty.id}")

      refute has_element?(view, "#play-collection")
    end

    test "the play control queues every track of the collection", %{conn: conn} do
      PlayingPipeline.use_it()
      {_artist, album} = collection_tree()
      with_tracks(album, 3)

      {:ok, view, _html} = live(conn, "#{@podcasts}/subscriptions/#{album.id}")

      view |> element("#play-collection") |> render_click()

      assert length(Playback.queue!()) == 3
    end
  end
end
