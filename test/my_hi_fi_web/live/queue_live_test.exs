defmodule MyHiFiWeb.QueueLiveTest do
  # `MyHiFi.Playback.Queue` is on ETS and the table is not private, so its rows outlive
  # one test in the way that `MyHiFi.Player` does.
  use MyHiFiWeb.ConnCase, async: false

  alias MyHiFi.Playback

  setup do
    MyHiFi.Player.stop()
    Playback.clear_queue!()

    on_exit(fn ->
      MyHiFi.Player.stop()
      Playback.clear_queue!()
    end)

    :ok
  end

  describe "a queue that holds nothing" do
    test "it says so, and it offers nothing to clear", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/queue")

      assert has_element?(view, "#queue-empty")
      refute has_element?(view, "#clear-queue")
    end
  end

  describe "a queue that holds rows" do
    setup do
      rows = queue(["Alpha", "Bravo", "Charlie"])

      %{rows: rows}
    end

    test "it draws every row in the order that it plays", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/queue")

      refute has_element?(view, "#queue-empty")
      assert titles_on(view) == ["Alpha", "Bravo", "Charlie"]
    end

    # A person reads which row the player has, and the mark is not the colour alone.
    test "it says which row plays", %{conn: conn, rows: rows} do
      playing = Enum.find(rows, & &1.playing?)

      {:ok, view, _html} = live(conn, ~p"/queue")

      assert has_element?(view, "#queue-#{playing.id} [aria-label='Playing now']")
    end

    # **A person who presses a row keeps the queue.** A page that passed one identifier
    # would throw the rest of it away.
    test "pressing a row keeps every other row", %{conn: conn, rows: rows} do
      third = Enum.find(rows, &(&1.position == 2))

      {:ok, view, _html} = live(conn, ~p"/queue")

      view |> element("#play-#{third.id}") |> render_click()

      assert titles_on(view) == ["Alpha", "Bravo", "Charlie"]
      assert playing_title() == "Charlie"
    end

    test "a row that a person takes out goes, and the rest close around it", %{
      conn: conn,
      rows: rows
    } do
      first = Enum.find(rows, &(&1.position == 0))

      {:ok, view, _html} = live(conn, ~p"/queue")

      view |> element("#remove-#{first.id}") |> render_click()

      assert titles_on(view) == ["Bravo", "Charlie"]
      assert Enum.map(Playback.queue!(), & &1.position) == [0, 1]
    end

    test "a row moves up and down", %{conn: conn, rows: rows} do
      third = Enum.find(rows, &(&1.position == 2))

      {:ok, view, _html} = live(conn, ~p"/queue")

      view |> element("#up-#{third.id}") |> render_click()
      assert titles_on(view) == ["Alpha", "Charlie", "Bravo"]

      view |> element("#down-#{third.id}") |> render_click()
      assert titles_on(view) == ["Alpha", "Bravo", "Charlie"]
    end

    # A person who presses "up" on the first row means the first row, so the control is
    # not there to press.
    test "the ends hold no control that would do nothing", %{conn: conn, rows: rows} do
      first = Enum.find(rows, &(&1.position == 0))
      last = Enum.find(rows, &(&1.position == 2))

      {:ok, view, _html} = live(conn, ~p"/queue")

      assert has_element?(view, "#up-#{first.id}[disabled]")
      assert has_element?(view, "#down-#{last.id}[disabled]")
      refute has_element?(view, "#down-#{first.id}[disabled]")
      refute has_element?(view, "#up-#{last.id}[disabled]")
    end

    # **A move never moves the mark.** A person who moves a row means to change what
    # comes next, and not to change what they are listening to now.
    test "a move leaves the player alone", %{conn: conn, rows: rows} do
      third = Enum.find(rows, &(&1.position == 2))

      {:ok, view, _html} = live(conn, ~p"/queue")

      view |> element("#up-#{third.id}") |> render_click()

      assert playing_title() == "Bravo"
    end

    test "a person empties the whole queue", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/queue")

      html = view |> element("#clear-queue") |> render_click()

      assert html =~ "The queue is empty"
      assert has_element?(view, "#queue-empty")
      assert Playback.queue!() == []
    end

    # The player moves the mark when a track ends, and no person pressed anything.
    test "an event of the player draws the queue again", %{conn: conn, rows: rows} do
      {:ok, view, _html} = live(conn, ~p"/queue")

      first = Enum.find(rows, &(&1.position == 0))
      {:ok, _row} = Playback.remove_from_queue(first.id)

      MyHiFi.Event.publish(:player, %MyHiFi.Event.Player.Stopped{reason: :requested})

      assert titles_on(view) == ["Bravo", "Charlie"]
    end
  end

  # **A row of an item that no longer exists draws nothing.** A page cannot say what a
  # person removed from the catalogue, and a queue row outlives a sync that took the
  # item away.
  test "a row whose item is gone draws no row", %{conn: conn} do
    [first, second] = queue(["Alpha", "Bravo"])

    Playback.get_item!(second.item_id) |> Ash.destroy!()

    {:ok, view, _html} = live(conn, ~p"/queue")

    assert titles_on(view) == ["Alpha"]
    assert has_element?(view, "#queue-#{first.id}")
    refute has_element?(view, "#queue-#{second.id}")
  end

  defp queue(titles) do
    ids = Enum.map(titles, &item(&1).id)
    {:ok, rows} = Playback.replace_queue(ids, %{playing_index: 1})

    Enum.sort_by(rows, & &1.position)
  end

  defp item(title) do
    Playback.upsert_item!(%{
      source: "internet-radio",
      source_ref: "station-#{System.unique_integer([:positive])}",
      title: title
    })
  end

  # The order of the rows is what a person reads, so this reads the page and not the
  # queue.
  #
  # It reads inside `#queue` alone. The sticky player draws the title of the track that
  # plays as well, and it draws it higher up the page, so a read of the whole document
  # would find that title twice.
  defp titles_on(view) do
    view
    |> element("#queue")
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("li [data-title]")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp playing_title do
    case Playback.queue_playing!() do
      nil -> nil
      row -> Playback.get_item!(row.item_id).title
    end
  end
end
