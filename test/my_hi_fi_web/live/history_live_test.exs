defmodule MyHiFiWeb.HistoryLiveTest do
  use MyHiFiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MyHiFi.Playback
  alias MyHiFi.Source
  alias MyHiFi.Test.Stations

  # `render_async/1` waits `:assert_receive_timeout`, and `mix check` runs the suite
  # beside every other tool. See `MyHiFiWeb.BrowseLiveTest`.
  @async_wait :timer.seconds(5)

  setup do
    for module <- Source.all(), do: Source.enable(module, true)

    :ok
  end

  defp list(view), do: view |> element("#history") |> render()

  defp heard(station) do
    {:ok, item} = Playback.mark_started(station)

    item
  end

  describe "the history" do
    test "a device that played nothing says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/history")

      assert render_async(view, @async_wait) =~ "played nothing yet"
    end

    test "an item that the device played is in the list", %{conn: conn} do
      Stations.create(%{title: "Newstalk ZB"}) |> heard()

      {:ok, view, _html} = live(conn, ~p"/history")
      render_async(view, @async_wait)

      assert list(view) =~ "Newstalk ZB"
    end

    test "an item that the device never played is absent", %{conn: conn} do
      Stations.create(%{title: "Newstalk ZB"}) |> heard()
      Stations.create(%{title: "The Sound"})

      {:ok, view, _html} = live(conn, ~p"/history")
      render_async(view, @async_wait)

      assert list(view) =~ "Newstalk ZB"
      refute list(view) =~ "The Sound"
    end

    # A person who played an album twelve times wants to find the album, and twelve
    # rows of it would push everything else off the page.
    test "a second play of one item gives one row, with the later time" do
      station = Stations.create(%{title: "Newstalk ZB"})

      first = heard(station)
      later = heard(station)

      assert DateTime.compare(later.last_started_at, first.last_started_at) in [:gt, :eq]
      assert length(Playback.history!()) == 1
    end

    test "the most recent play comes first" do
      one = Stations.create(%{title: "Newstalk ZB"}) |> heard()
      two = Stations.create(%{title: "The Sound"}) |> heard()

      titles = Playback.history!() |> Enum.map(& &1.title)

      assert titles == [two.title, one.title]
    end

    test "a row of a source that a person took out of use is absent", %{conn: conn} do
      Stations.create(%{title: "Newstalk ZB"}) |> heard()
      Source.enable(Source.InternetRadio, false)

      {:ok, view, _html} = live(conn, ~p"/history")
      render_async(view, @async_wait)

      refute list(view) =~ "Newstalk ZB"
    end

    test "the top row holds a control that reaches the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/browse/internet-radio")

      assert has_element?(view, "#history-link")
    end
  end

  # **`last_played_at` says that a person is done with an item, and this says that they
  # heard it.** A station never reaches an end, so it never held the other column.
  describe "the two columns of a play" do
    test "a play of a station writes the time that it was heard and not the other one" do
      station = Stations.create(%{title: "Newstalk ZB"}) |> heard()

      assert station.last_started_at
      refute station.last_played_at
      refute station.played?
    end
  end
end
