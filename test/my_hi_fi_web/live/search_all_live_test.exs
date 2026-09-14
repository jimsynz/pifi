defmodule MyHiFiWeb.SearchAllLiveTest do
  use MyHiFiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MyHiFi.Jellyfin.Fill, as: JellyfinFill
  alias MyHiFi.Source
  alias MyHiFi.Test.Stations

  setup do
    # A source that needs an address or a key is out of use until a person sets it up,
    # and this page reads every source in use. See `MyHiFi.Source.enabled?/1`.
    for module <- Source.all(), do: Source.enable(module, true)

    :ok
  end

  defp page(view), do: view |> element("#search-all") |> render()

  defp find(view, text) do
    view |> form("#search-all-form", %{"search" => text}) |> render_submit()

    page(view)
  end

  # An artist and an album are both containers, and the page must say which is which.
  # See `MyHiFi.Source.Jellyfin.search_groups/1`.
  defp library do
    JellyfinFill.artists([
      %{ref: "artist-1", title: "Altered Images", parent_ref: nil, artwork_url: nil}
    ])

    JellyfinFill.albums([
      %{
        ref: "album-1",
        title: "Alternative Light Source",
        parent_ref: "artist-1",
        artwork_url: nil,
        subtitle: "Leftfield"
      }
    ])

    JellyfinFill.tracks([
      %{
        ref: "track-1",
        title: "Altitude",
        parent_ref: "album-1",
        artwork_url: nil,
        subtitle: "W O L F C L U B",
        duration_ms: 1000,
        byte_size: 100,
        number: 1,
        format: :flac
      }
    ])
  end

  describe "the page before a person searches" do
    test "it reads nothing and it says what to do", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search")

      assert has_element?(view, "#search-all-prompt")
      refute has_element?(view, "#search-all-empty")
    end

    test "the top row holds a control that reaches it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/browse/internet-radio")

      assert has_element?(view, "#search-link")
    end
  end

  describe "a search of every source" do
    test "it groups the rows by source and by kind, and it counts each group", %{conn: conn} do
      library()
      Stations.create(%{title: "93.5 Eagle Radio - The True Alternative"})

      {:ok, view, _html} = live(conn, ~p"/search")

      html = find(view, "alt")

      assert html =~ "Artists"
      assert html =~ "Altered Images"
      assert html =~ "Albums"
      assert html =~ "Alternative Light Source"
      assert html =~ "Tracks"
      assert html =~ "Altitude"
      assert html =~ "Stations"
      assert html =~ "93.5 Eagle Radio"

      # One row in each of the four groups.
      assert html =~ "(1)"
    end

    test "a group that matches nothing is absent", %{conn: conn} do
      library()

      html = live(conn, ~p"/search") |> elem(1) |> find("altered")

      assert html =~ "Altered Images"
      refute html =~ "Alternative Light Source"
    end

    test "the text does not have to match the case", %{conn: conn} do
      Stations.create(%{title: "RNZ National"})

      html = live(conn, ~p"/search") |> elem(1) |> find("rnz")

      assert html =~ "RNZ National"
    end

    test "a text that nothing matches says so", %{conn: conn} do
      library()

      {:ok, view, _html} = live(conn, ~p"/search")

      find(view, "a name that no row holds")

      assert has_element?(view, "#search-all-empty")
    end

    # A person keeps the address of a search, so the text goes in it and a reload reads
    # the same list.
    test "the text of the address gives the groups at once", %{conn: conn} do
      library()

      {:ok, view, _html} = live(conn, ~p"/search?search=altitude")

      assert page(view) =~ "Altitude"
      assert has_element?(view, "#search-all-form")
    end

    test "a source that a person took out of use is absent", %{conn: conn} do
      library()
      Source.enable(Source.Jellyfin, false)

      html = live(conn, ~p"/search") |> elem(1) |> find("alt")

      refute html =~ "Altered Images"
    end
  end

  describe "the heading of a group" do
    test "it reaches the page of that source, with the text and the group", %{conn: conn} do
      library()

      {:ok, view, _html} = live(conn, ~p"/search")
      find(view, "alt")

      assert view
             |> element("#heading-jellyfin-albums")
             |> render() =~ "search=alt"

      assert view |> element("#heading-jellyfin-albums") |> render() =~ "group=Albums"
    end

    test "the page of that group reads the group alone", %{conn: conn} do
      library()

      {:ok, _view, html} =
        live(conn, ~p"/search/jellyfin?#{[search: "alt", group: "Albums"]}")

      assert html =~ "Alternative Light Source"
      refute html =~ "Altered Images"
    end

    # A person may keep such an address, and a source may rename a group.
    test "a group that the source does not hold reads the whole source", %{conn: conn} do
      library()

      {:ok, _view, html} =
        live(conn, ~p"/search/jellyfin?#{[search: "alt", group: "A group that went"]}")

      assert html =~ "Altered Images"
      assert html =~ "Alternative Light Source"
    end
  end
end
