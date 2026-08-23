defmodule MyHiFiWeb.BrowseLiveTest do
  use MyHiFiWeb.ConnCase, async: false

  alias MyHiFi.Event
  alias MyHiFi.Event.Player, as: Events
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
    def icon, do: :library

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

    @impl MyHiFi.Source
    def store_position(_ref, _position_ms), do: :ok

    @impl MyHiFi.Source
    def finished(_ref), do: :ok

    @impl MyHiFi.Source
    def ref_to_string(:only), do: {:ok, "only"}

    @impl MyHiFi.Source
    def ref_from_string("only"), do: {:ok, :only}
    def ref_from_string(_name), do: {:error, :not_a_name}

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

  defmodule ShowSource do
    @moduledoc """
    A source that marks a container and not a track.

    Podcasts subscribe to a show, and a show is a container. Internet radio marks
    a station, and a station is a track. This source reaches the container half of
    the control, and it keeps the mark in the process dictionary of the test.
    """

    @behaviour MyHiFi.Source

    @impl MyHiFi.Source
    def title, do: "Show source"

    @impl MyHiFi.Source
    def icon, do: :podcast

    @impl MyHiFi.Source
    def root, do: :root

    @impl MyHiFi.Source
    def browse(:root, _options) do
      {:ok,
       %{
         entries: [
           {:container, %{ref: :show, title: "A show", artwork: nil, favourite?: marked?()}},
           {:container, %{ref: :plain, title: "No mark here", artwork: nil, favourite?: nil}}
         ],
         cursor: nil
       }}
    end

    def browse(:show, _options), do: {:ok, %{entries: [], cursor: nil}}

    @impl MyHiFi.Source
    def search(_query, _options), do: {:error, :not_supported}

    @impl MyHiFi.Source
    def track(ref), do: {:error, {:not_a_track, ref}}

    @impl MyHiFi.Source
    def resolve(ref), do: {:error, {:not_a_track, ref}}

    @impl MyHiFi.Source
    def favourite(:show, true?) do
      Application.put_env(:my_hi_fi, __MODULE__, true?)
      :ok
    end

    def favourite(ref, _true?), do: {:error, {:not_a_track, ref}}

    @impl MyHiFi.Source
    def store_position(_ref, _position_ms), do: :ok

    @impl MyHiFi.Source
    def finished(_ref), do: :ok

    @impl MyHiFi.Source
    def ref_to_string(_ref), do: {:error, :cannot_name}

    @impl MyHiFi.Source
    def ref_from_string(_name), do: {:error, :not_a_name}

    def marked?, do: Application.get_env(:my_hi_fi, __MODULE__, false)
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

    on_exit(fn ->
      Application.delete_env(:my_hi_fi, :sources)
      # A test source that keeps state keeps it here, and one test must not reach
      # the next one.
      Application.delete_env(:my_hi_fi, module)
    end)
  end

  setup do
    # `MyHiFi.Player` is one process for the whole node, so its state outlives a
    # test.
    MyHiFi.Player.stop()
    on_exit(fn -> MyHiFi.Player.stop() end)
    :ok
  end

  describe "the source of the page" do
    test "the top row holds one control for each source", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/browse/internet-radio")

      assert html =~ "Internet radio"
      assert has_element?(view, "#source-internet-radio")
      assert has_element?(view, "#settings-link")
    end

    test "the address of a source shows the top of its tree", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/browse/internet-radio")

      assert html =~ "Favourites"
      assert html =~ "Countries"
      assert html =~ "Tags"
      assert has_element?(view, "#crumbs")
    end

    test "the first source shows for an address with no source", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/browse/internet-radio"}}} = live(conn, ~p"/")
    end

    test "a name that no source holds shows the first source", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/browse/internet-radio"}}} =
               live(conn, ~p"/browse/gramophone")
    end
  end

  describe "moving through the tree" do
    test "a person reaches a station through the countries", %{conn: conn} do
      station(%{title: "RNZ National", country_code: "NZ"})

      {:ok, view, _html} = live(conn, ~p"/browse/internet-radio")
      html = open(view, "Countries")

      assert html =~ "NZ"

      html = open(view, "NZ")

      assert html =~ "RNZ National"
      assert html =~ "MP3, 128 kbps"
    end

    test "a person reaches a station through the tags", %{conn: conn} do
      station(%{title: "Tagged", tags: ["jazz"]})

      {:ok, view, _html} = live(conn, ~p"/browse/internet-radio")
      open(view, "Tags")
      html = open(view, "jazz")

      assert html =~ "Tagged"
    end

    test "a crumb goes back to a container that the person left", %{conn: conn} do
      station(%{title: "RNZ National", country_code: "NZ"})

      {:ok, view, _html} = live(conn, ~p"/browse/internet-radio")
      open(view, "Countries")
      open(view, "NZ")

      html = view |> element("#crumb-1") |> render_click()

      assert html =~ "NZ"
      refute html =~ "RNZ National"
    end

    test "a container with nothing in it says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/browse/internet-radio")
      html = open(view, "Favourites")

      assert html =~ "Nothing here."
    end
  end

  describe "search" do
    test "finds a station by part of its title", %{conn: conn} do
      station(%{title: "RNZ National"})
      station(%{title: "Radio Hauraki"})

      {:ok, view, _html} = live(conn, ~p"/browse/internet-radio")

      html =
        view
        |> form("#search-form", search: %{query: "hauraki"})
        |> render_submit()

      assert html =~ "Radio Hauraki"
      refute html =~ "RNZ National"
    end

    test "clearing the search gives the tree again", %{conn: conn} do
      station(%{title: "Radio Hauraki"})

      {:ok, view, _html} = live(conn, ~p"/browse/internet-radio")
      view |> form("#search-form", search: %{query: "hauraki"}) |> render_submit()

      html = view |> element("#clear-search") |> render_click()

      assert html =~ "Favourites"
      refute html =~ "Radio Hauraki"
    end

    test "an empty query gives the tree again", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/browse/internet-radio")
      html = view |> form("#search-form", search: %{query: "   "}) |> render_submit()

      assert html =~ "Favourites"
    end

    test "the field goes away for a source with no search", %{conn: conn} do
      use_source(PlainSource)

      {:ok, view, _html} = live(conn, ~p"/browse/plain-source")

      assert has_element?(view, "#search-form")

      html = view |> form("#search-form", search: %{query: "anything"}) |> render_submit()

      assert html =~ "This source has no search."
      refute has_element?(view, "#search-form")
      assert html =~ "One track"
    end
  end

  describe "the marker of the entry that plays" do
    test "the entry that plays holds the marker, and another entry holds none", %{conn: conn} do
      playing = station(%{title: "RNZ National", country_code: "NZ"})
      station(%{title: "RNZ Concert", country_code: "NZ"})

      {:ok, view, _html} = live(conn, ~p"/browse/internet-radio")
      open(view, "Countries")
      open(view, "NZ")

      Event.publish(:player, %Events.Started{
        source: MyHiFi.Source.InternetRadio,
        track: %{ref: {:station, playing.id}, title: "RNZ National"},
        artwork_path: nil,
        live?: true
      })

      assert has_element?(view, ~s(button[aria-current="true"]), "RNZ National")
      refute has_element?(view, ~s(button[aria-current="true"]), "RNZ Concert")
    end

    test "a stop removes the marker", %{conn: conn} do
      playing = station(%{title: "RNZ National", country_code: "NZ"})

      {:ok, view, _html} = live(conn, ~p"/browse/internet-radio")
      open(view, "Countries")
      open(view, "NZ")

      Event.publish(:player, %Events.Started{
        source: MyHiFi.Source.InternetRadio,
        track: %{ref: {:station, playing.id}, title: "RNZ National"},
        artwork_path: nil,
        live?: true
      })

      assert has_element?(view, ~s(#play-0[aria-current="true"]))

      Event.publish(:player, %Events.Stopped{reason: :requested})

      refute has_element?(view, ~s(#play-0[aria-current="true"]))
    end

    # A station of another source cannot hold the marker of this list.
    test "an entry of another source holds no marker", %{conn: conn} do
      station(%{title: "RNZ National", country_code: "NZ"})

      {:ok, view, _html} = live(conn, ~p"/browse/internet-radio")
      open(view, "Countries")
      open(view, "NZ")

      Event.publish(:player, %Events.Started{
        source: PlainSource,
        track: %{ref: :only, title: "One track"},
        artwork_path: nil,
        live?: false
      })

      refute has_element?(view, ~s(#play-0[aria-current="true"]))
    end
  end

  describe "favourites" do
    test "a person makes a station a favourite, and removes that mark", %{conn: conn} do
      station(%{title: "RNZ National", country_code: "NZ"})

      {:ok, view, _html} = live(conn, ~p"/browse/internet-radio")
      open(view, "Countries")
      open(view, "NZ")

      html = view |> element("#favourite-0") |> render_click()

      assert html =~ "hero-star-solid"
      assert [%{favourite?: true}] = Radio.favourite_stations!()

      html = view |> element("#favourite-0") |> render_click()

      refute html =~ "hero-star-solid"
      assert [] == Radio.favourite_stations!()
    end

    test "the favourites container lists what the person marked", %{conn: conn} do
      created = station(%{title: "RNZ Concert"})
      Radio.set_favourite!(created)

      {:ok, view, _html} = live(conn, ~p"/browse/internet-radio")
      html = open(view, "Favourites")

      assert html =~ "RNZ Concert"
    end

    test "the control goes away for a source with no favourites", %{conn: conn} do
      use_source(PlainSource)

      {:ok, view, _html} = live(conn, ~p"/browse/plain-source")

      assert has_element?(view, "#play-0")
      refute has_element?(view, "#favourite-0")
    end

    test "a person marks a container, and removes that mark", %{conn: conn} do
      use_source(ShowSource)

      {:ok, view, html} = live(conn, ~p"/browse/show-source")

      assert html =~ "A show"
      refute html =~ "hero-star-solid"

      html = view |> element("#favourite-0") |> render_click()

      assert html =~ "hero-star-solid"
      assert ShowSource.marked?()

      html = view |> element("#favourite-0") |> render_click()

      refute html =~ "hero-star-solid"
      refute ShowSource.marked?()
    end

    test "a container with no mark draws no control", %{conn: conn} do
      use_source(ShowSource)

      {:ok, view, _html} = live(conn, ~p"/browse/show-source")

      # The first container carries the mark, and the second carries none.
      assert has_element?(view, "#favourite-0")
      refute has_element?(view, "#favourite-1")
      assert has_element?(view, "#open-1")
    end

    test "a marked container still opens", %{conn: conn} do
      use_source(ShowSource)

      {:ok, view, _html} = live(conn, ~p"/browse/show-source")
      view |> element("#favourite-0") |> render_click()

      html = view |> element("#open-0") |> render_click()

      assert html =~ "Nothing here."
    end
  end

  describe "play" do
    test "a track that the source cannot resolve shows the reason", %{conn: conn} do
      use_source(PlainSource)

      {:ok, view, _html} = live(conn, ~p"/browse/plain-source")
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

      {:ok, view, _html} = live(conn, ~p"/browse/internet-radio")
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
