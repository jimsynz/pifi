defmodule MyHiFiWeb.SearchLiveTest do
  use MyHiFiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MyHiFi.Event
  alias MyHiFi.Playback
  alias MyHiFi.Podcast.Fill, as: PodcastFill
  alias MyHiFi.Source
  alias MyHiFi.Test.Stations

  @radio Source.slug(Source.InternetRadio)
  @podcasts Source.slug(Source.Podcasts)

  # Cinder draws the search input inside the form that holds the filters of the
  # collection, and the name of it is `search`.
  # The player of a test before this one may still hold a track, and the name of it is
  # in the bar at the top of every page. A refute must therefore read the list alone.
  defp list(view), do: view |> element("#search") |> render()

  defp find(view, text) do
    view |> form("#search-filter-form", %{"search" => text}) |> render_change()
  end

  describe "finding a station" do
    test "the text of the address gives the list at once", %{conn: conn} do
      Stations.create(%{title: "Newstalk ZB"})
      Stations.create(%{title: "The Sound"})

      {:ok, view, _html} = live(conn, ~p"/search/#{@radio}?search=newstalk")

      assert list(view) =~ "Newstalk ZB"
      refute list(view) =~ "The Sound"
    end

    # Cinder asks for `contains` with an `Ash.CiString`, and that compiles to
    # `instr(title, ? COLLATE NOCASE)`. `instr` of SQLite reads no collation, so the
    # matching of this page puts both sides in lower case instead.
    test "the case of the text does not matter", %{conn: conn} do
      Stations.create(%{title: "RNZ National"})

      for text <- ["rnz", "RNZ", "Rnz", "national"] do
        {:ok, _view, html} = live(conn, ~p"/search/#{@radio}?search=#{text}")

        assert html =~ "RNZ National", "#{text} found nothing"
      end
    end

    # `like` reads these as wildcards, and a person means them as text.
    test "a percent and an underscore are text and not wildcards", %{conn: conn} do
      Stations.create(%{title: "Newstalk ZB"})

      {:ok, view, _html} = live(conn, ~p"/search/#{@radio}?search=%")

      refute list(view) =~ "Newstalk ZB"
      assert list(view) =~ "Nothing matches that."
    end

    # `MyHiFiWeb.ItemList` holds the subscription and the read, so this page names
    # neither one. See that module.
    test "the list reads again when a source says that it changed", %{conn: conn} do
      Stations.create(%{title: "Newstalk ZB"})

      {:ok, view, _html} = live(conn, ~p"/search/#{@radio}?search=newstalk")

      assert list(view) =~ "Newstalk ZB"
      refute list(view) =~ "Newstalk ZB Wellington"

      Stations.create(%{title: "Newstalk ZB Wellington"})
      Event.publish(:source, %Event.Source.Changed{source: Source.InternetRadio, ref: :station})

      assert render_async(view) =~ "Newstalk ZB Wellington"
    end

    test "a station of another source is not in the list", %{conn: conn} do
      Stations.create(%{title: "Newstalk ZB"})

      {:ok, view, _html} = live(conn, ~p"/search/#{@podcasts}?search=newstalk")

      refute list(view) =~ "Newstalk ZB"
    end

    test "a station of the list plays", %{conn: conn} do
      Stations.create(%{title: "Newstalk ZB"})

      {:ok, view, _html} = live(conn, ~p"/search/#{@radio}?search=newstalk")
      [item] = Playback.items_of_source!("internet-radio")

      assert view |> element("#play-#{item.id}") |> render_click() =~ "Playing Newstalk ZB"
    end

    test "a station of the list takes a mark", %{conn: conn} do
      Stations.create(%{title: "Newstalk ZB"})

      {:ok, view, _html} = live(conn, ~p"/search/#{@radio}?search=newstalk")
      [item] = Playback.items_of_source!("internet-radio")

      view |> element("#favourite-#{item.id}") |> render_click()

      assert {:ok, %{favourite?: true}} = Playback.get_item(item.id)
    end
  end

  describe "finding a show" do
    test "a show that the device holds is in the list", %{conn: conn} do
      PodcastFill.show(%{feed_url: "https://example.test/rss", title: "Road Work"})

      {:ok, _view, html} = live(conn, ~p"/search/#{@podcasts}?search=road")

      assert html =~ "Road Work"
    end

    test "a show and an episode are both in the list", %{conn: conn} do
      show = PodcastFill.show(%{feed_url: "https://example.test/rss", title: "Road Work"})

      PodcastFill.episodes(show, "https://example.test/rss", [
        %{
          guid: "one",
          title: "Road Work, the first one",
          audio_url: "https://example.test/1.mp3",
          mime_type: "audio/mpeg",
          duration_ms: 2_921_000,
          published_at: ~U[2022-06-02 14:00:00Z]
        }
      ])

      {:ok, view, _html} = live(conn, ~p"/search/#{@podcasts}?search=road")

      assert list(view) =~ "Road Work"
      assert list(view) =~ "the first one"
    end
  end

  # A source names what a person calls its items, and the control is worth drawing only
  # for a source that holds more than one kind. See `c:MyHiFi.Source.kinds/0`.
  describe "the control that chooses a kind" do
    setup %{conn: conn} do
      show = PodcastFill.show(%{feed_url: "https://example.test/rss", title: "Road Work"})

      PodcastFill.episodes(show, "https://example.test/rss", [
        %{
          guid: "one",
          title: "Road Work, the first one",
          audio_url: "https://example.test/1.mp3",
          mime_type: "audio/mpeg",
          duration_ms: 2_921_000,
          published_at: ~U[2022-06-02 14:00:00Z]
        }
      ])

      %{conn: conn}
    end

    test "it names the kinds of the source", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/search/#{@podcasts}?search=road")

      assert html =~ "Shows"
      assert html =~ "Episodes"
    end

    test "a kind narrows the list to it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search/#{@podcasts}?search=road")

      view
      |> form("#search-filter-form", %{"search" => "road", "filters" => %{"kind" => "container"}})
      |> render_change()

      assert list(view) =~ "Road Work"
      refute list(view) =~ "the first one"
    end

    test "the kind goes into the address", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search/#{@podcasts}?search=road")

      view
      |> form("#search-filter-form", %{"search" => "road", "filters" => %{"kind" => "track"}})
      |> render_change()

      assert assert_patch(view) =~ "kind=track"
    end

    # Internet radio holds stations and nothing else, so there is nothing to choose.
    test "a source of one kind holds no such control", %{conn: conn} do
      Stations.create(%{title: "Newstalk ZB"})

      {:ok, view, _html} = live(conn, ~p"/search/#{@radio}?search=newstalk")

      refute has_element?(view, "#search-filter-kind")
    end
  end

  # A container never plays, so a row of one opens. This page held no such event at all,
  # and pressing a show of the results stopped the view.
  describe "opening a show of the results" do
    test "it gives the episodes of that show on the browse page", %{conn: conn} do
      show = PodcastFill.show(%{feed_url: "https://example.test/rss", title: "Road Work"})

      PodcastFill.episodes(show, "https://example.test/rss", [
        %{
          guid: "one",
          title: "The first one",
          audio_url: "https://example.test/1.mp3",
          mime_type: "audio/mpeg",
          duration_ms: 2_921_000,
          published_at: ~U[2022-06-02 14:00:00Z]
        }
      ])

      {:ok, view, _html} = live(conn, ~p"/search/#{@podcasts}?search=road")

      {:ok, _browse, html} =
        view |> element("#open-#{show.id}") |> render_click() |> follow_redirect(conn)

      assert html =~ "The first one"
      # The breadcrumbs name the show, and no branch above it.
      assert html =~ "Road Work"
    end
  end

  describe "the address" do
    test "the text goes into it, and a reload holds it", %{conn: conn} do
      Stations.create(%{title: "Newstalk ZB"})
      Stations.create(%{title: "The Sound"})

      {:ok, view, _html} = live(conn, ~p"/search/#{@radio}")

      find(view, "newstalk")

      assert assert_patch(view) =~ "search=newstalk"
      assert list(view) =~ "Newstalk ZB"
      refute list(view) =~ "The Sound"
    end

    test "a source that no person can search gives the browse page", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/search/nonsense")

      assert to == "/browse/nonsense"
    end
  end

  describe "the way back" do
    test "the name of the source gives the branches of it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search/#{@radio}?search=rnz")

      {:ok, _browse, html} =
        view |> element("#search nav a") |> render_click() |> follow_redirect(conn)

      assert html =~ "Favourites"
      assert html =~ "Countries"
    end
  end
end
