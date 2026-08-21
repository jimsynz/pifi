defmodule MyHiFiWeb.BrowseLiveTest do
  use MyHiFiWeb.ConnCase, async: false

  alias MyHiFi.Radio

  defmodule PlainSource do
    @moduledoc """
    A source with no search and no favourites.

    The page hides both controls for such a source, and internet radio holds
    both, so a test needs this one to reach the other half of the page.
    """

    @behaviour MyHiFi.Source

    @impl MyHiFi.Source
    def title, do: "Plain source"

    @impl MyHiFi.Source
    def root, do: :root

    @impl MyHiFi.Source
    def browse(:root, _options) do
      {:ok, %{entries: [{:track, track()}], cursor: nil}}
    end

    @impl MyHiFi.Source
    def search(_query, _options), do: {:error, :not_supported}

    @impl MyHiFi.Source
    def track(:only), do: {:ok, track()}

    @impl MyHiFi.Source
    def resolve(:only), do: {:error, :cannot_play}

    @impl MyHiFi.Source
    def favourite(_ref, _true?), do: {:error, :not_supported}

    defp track do
      %{
        ref: :only,
        title: "One track",
        subtitle: nil,
        artwork: nil,
        duration_ms: nil,
        favourite?: nil
      }
    end
  end

  defp station(overrides) do
    defaults = %{
      remote_id: "remote-#{System.unique_integer([:positive])}",
      title: "Station #{System.unique_integer([:positive])}",
      stream_url: "http://example.test/stream.mp3",
      codec: "MP3",
      bitrate: 128,
      hls?: false,
      country_code: "NZ",
      tags: ["news"],
      click_count: 0
    }

    Radio.upsert_station_from_remote!(Map.merge(defaults, overrides))
  end

  defp use_source(module) do
    Application.put_env(:my_hi_fi, :sources, [module])
    on_exit(fn -> Application.delete_env(:my_hi_fi, :sources) end)
  end

  setup do
    # `MyHiFi.Player` is one process for the whole node, so its state outlives a
    # test.
    MyHiFi.Player.stop()
    on_exit(fn -> MyHiFi.Player.stop() end)
    :ok
  end

  describe "the source list" do
    test "names each source", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/browse")

      assert html =~ "Internet radio"
      assert has_element?(view, "#source-0")
      refute has_element?(view, "#entries")
    end

    test "choosing a source shows the top of its tree", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/browse")

      html = view |> element("#source-0") |> render_click()

      assert html =~ "Favourites"
      assert html =~ "Countries"
      assert html =~ "Tags"
      assert has_element?(view, "#crumbs")
    end
  end

  describe "moving through the tree" do
    test "a person reaches a station through the countries", %{conn: conn} do
      station(%{title: "RNZ National", country_code: "NZ"})

      {:ok, view, _html} = live(conn, ~p"/browse")

      view |> element("#source-0") |> render_click()
      html = open(view, "Countries")

      assert html =~ "NZ"

      html = open(view, "NZ")

      assert html =~ "RNZ National"
      assert html =~ "MP3, 128 kbps"
    end

    test "a person reaches a station through the tags", %{conn: conn} do
      station(%{title: "Tagged", tags: ["jazz"]})

      {:ok, view, _html} = live(conn, ~p"/browse")

      view |> element("#source-0") |> render_click()
      open(view, "Tags")
      html = open(view, "jazz")

      assert html =~ "Tagged"
    end

    test "a crumb goes back to a container that the person left", %{conn: conn} do
      station(%{title: "RNZ National", country_code: "NZ"})

      {:ok, view, _html} = live(conn, ~p"/browse")

      view |> element("#source-0") |> render_click()
      open(view, "Countries")
      open(view, "NZ")

      html = view |> element("#crumb-1") |> render_click()

      assert html =~ "NZ"
      refute html =~ "RNZ National"
    end

    test "the source list comes back", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/browse")

      view |> element("#source-0") |> render_click()
      html = view |> element("#crumbs button", "Sources") |> render_click()

      assert html =~ "Internet radio"
      refute has_element?(view, "#crumbs")
    end

    test "a container with nothing in it says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/browse")

      view |> element("#source-0") |> render_click()
      html = open(view, "Favourites")

      assert html =~ "Nothing here."
    end
  end

  describe "search" do
    test "finds a station by part of its title", %{conn: conn} do
      station(%{title: "RNZ National"})
      station(%{title: "Radio Hauraki"})

      {:ok, view, _html} = live(conn, ~p"/browse")

      view |> element("#source-0") |> render_click()

      html =
        view
        |> form("#search-form", search: %{query: "hauraki"})
        |> render_submit()

      assert html =~ "Radio Hauraki"
      refute html =~ "RNZ National"
    end

    test "clearing the search gives the tree again", %{conn: conn} do
      station(%{title: "Radio Hauraki"})

      {:ok, view, _html} = live(conn, ~p"/browse")

      view |> element("#source-0") |> render_click()
      view |> form("#search-form", search: %{query: "hauraki"}) |> render_submit()

      html = view |> element("#clear-search") |> render_click()

      assert html =~ "Favourites"
      refute html =~ "Radio Hauraki"
    end

    test "an empty query gives the tree again", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/browse")

      view |> element("#source-0") |> render_click()
      html = view |> form("#search-form", search: %{query: "   "}) |> render_submit()

      assert html =~ "Favourites"
    end

    test "the field goes away for a source with no search", %{conn: conn} do
      use_source(PlainSource)

      {:ok, view, _html} = live(conn, ~p"/browse")

      view |> element("#source-0") |> render_click()

      assert has_element?(view, "#search-form")

      html = view |> form("#search-form", search: %{query: "anything"}) |> render_submit()

      assert html =~ "This source has no search."
      refute has_element?(view, "#search-form")
      assert html =~ "One track"
    end
  end

  describe "favourites" do
    test "a person makes a station a favourite, and removes that mark", %{conn: conn} do
      station(%{title: "RNZ National", country_code: "NZ"})

      {:ok, view, _html} = live(conn, ~p"/browse")

      view |> element("#source-0") |> render_click()
      open(view, "Countries")
      open(view, "NZ")

      html = view |> element("#favourite-0") |> render_click()

      assert html =~ "★"
      assert [%{favourite?: true}] = Radio.favourite_stations!()

      html = view |> element("#favourite-0") |> render_click()

      assert html =~ "☆"
      assert [] == Radio.favourite_stations!()
    end

    test "the favourites container lists what the person marked", %{conn: conn} do
      created = station(%{title: "RNZ Concert"})
      Radio.set_favourite!(created)

      {:ok, view, _html} = live(conn, ~p"/browse")

      view |> element("#source-0") |> render_click()
      html = open(view, "Favourites")

      assert html =~ "RNZ Concert"
    end

    test "the control goes away for a source with no favourites", %{conn: conn} do
      use_source(PlainSource)

      {:ok, view, _html} = live(conn, ~p"/browse")

      view |> element("#source-0") |> render_click()

      assert has_element?(view, "#play-0")
      refute has_element?(view, "#favourite-0")
    end
  end

  describe "play" do
    test "a track that the source cannot resolve shows the reason", %{conn: conn} do
      use_source(PlainSource)

      {:ok, view, _html} = live(conn, ~p"/browse")

      view |> element("#source-0") |> render_click()
      html = view |> element("#play-0") |> render_click()

      assert html =~ "Could not play that"
      assert html =~ "cannot_play"
    end
  end

  describe "the page cursor" do
    test "a long list arrives one page at a time", %{conn: conn} do
      for index <- 1..101 do
        station(%{title: "Station #{String.pad_leading(to_string(index), 3, "0")}"})
      end

      {:ok, view, _html} = live(conn, ~p"/browse")

      view |> element("#source-0") |> render_click()
      open(view, "Countries")
      html = open(view, "NZ")

      assert html =~ "Station 001"
      refute html =~ "Station 101"
      assert has_element?(view, "#more")

      html = view |> element("#more") |> render_click()

      assert html =~ "Station 001"
      assert html =~ "Station 101"
      refute has_element?(view, "#more")
    end
  end

  defp open(view, title) do
    view |> element("#entries button", title) |> render_click()
  end
end
