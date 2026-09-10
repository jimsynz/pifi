defmodule MyHiFiWeb.PlaylistLiveTest do
  # A playlist plays through `MyHiFi.Playback.Queue`, which is on ETS and not private,
  # so its rows outlive one test in the way that `MyHiFi.Player` does.
  use MyHiFiWeb.ConnCase, async: false
  use Oban.Testing, repo: MyHiFi.Repo

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

  defp item(title) do
    Playback.upsert_item!(%{
      source: "internet-radio",
      source_ref: "station-#{System.unique_integer([:positive])}",
      title: title
    })
  end

  defp playlist(name, titles) do
    made = Playback.create_playlist!(name)
    ids = Enum.map(titles, &item(&1).id)
    {:ok, entries} = Playback.add_to_playlist(made.id, ids)

    {made, Enum.sort_by(entries, & &1.position)}
  end

  defp titles_on(view) do
    view
    |> element("#playlist")
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("li [data-title]")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  describe "a device that made no playlist" do
    test "it says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/playlists")

      assert has_element?(view, "#playlists-empty")
    end

    # **The queue is what fills the first playlist.** A person plays a list and then
    # keeps it.
    test "a person keeps the queue as a playlist", %{conn: conn} do
      ids = Enum.map(["Alpha", "Bravo"], &item(&1).id)
      {:ok, _rows} = Playback.replace_queue(ids, %{playing_index: 0})

      {:ok, view, _html} = live(conn, ~p"/playlists")

      view |> element("#keep-queue") |> render_click()
      html = view |> form("#keep-queue-form", %{"name" => "Friday"}) |> render_submit()

      assert html =~ "Friday has 2 tracks"
      assert [made] = Playback.list_playlists!()
      assert to_string(made.name) == "Friday"
      assert Playback.playlist_item_ids!(made.id) == ids
    end

    test "an empty queue keeps nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/playlists")

      view |> element("#keep-queue") |> render_click()
      html = view |> form("#keep-queue-form", %{"name" => "Friday"}) |> render_submit()

      assert html =~ "The queue is empty"
      assert Playback.list_playlists!() == []
    end

    test "a name that another playlist has says so", %{conn: conn} do
      {_made, _entries} = playlist("Friday", ["Alpha"])
      {:ok, _rows} = Playback.replace_queue([item("Bravo").id], %{playing_index: 0})

      {:ok, view, _html} = live(conn, ~p"/playlists")

      view |> element("#keep-queue") |> render_click()
      html = view |> form("#keep-queue-form", %{"name" => "Friday"}) |> render_submit()

      assert html =~ "Another playlist has that name"
    end
  end

  describe "the list of playlists" do
    test "it draws each one and says how many tracks it carries", %{conn: conn} do
      {made, _entries} = playlist("Friday", ["Alpha", "Bravo"])
      {alone, _entries} = playlist("Sunday", ["Charlie"])

      {:ok, view, _html} = live(conn, ~p"/playlists")

      assert has_element?(view, "#playlist-#{made.id}", "2 tracks")
      assert has_element?(view, "#playlist-#{alone.id}", "1 track")
    end

    test "a press plays the whole playlist", %{conn: conn} do
      {made, _entries} = playlist("Friday", ["Alpha", "Bravo"])

      {:ok, view, _html} = live(conn, ~p"/playlists")

      view |> element("#play-playlist-#{made.id}") |> render_click()

      assert Playback.queue!() |> Enum.map(& &1.item_id) ==
               Playback.playlist_item_ids!(made.id)
    end

    # Adding to the queue plays nothing and changes nothing that is playing, which is
    # the rule that a row of a list follows. See `MyHiFiWeb.ItemList`.
    test "a press adds the whole playlist to the queue", %{conn: conn} do
      playing = item("Playing")
      {:ok, _rows} = Playback.replace_queue([playing.id], %{playing_index: 0})
      {made, _entries} = playlist("Friday", ["Alpha", "Bravo"])

      {:ok, view, _html} = live(conn, ~p"/playlists")

      view |> element("#queue-playlist-#{made.id}") |> render_click()

      assert Playback.queue!() |> Enum.map(& &1.item_id) ==
               [playing.id | Playback.playlist_item_ids!(made.id)]
    end

    test "an empty playlist plays nothing", %{conn: conn} do
      made = Playback.create_playlist!("Empty")

      {:ok, view, _html} = live(conn, ~p"/playlists")

      html = view |> element("#play-playlist-#{made.id}") |> render_click()

      assert html =~ "That playlist is empty"
      assert Playback.queue!() == []
    end
  end

  describe "one playlist" do
    setup do
      {made, entries} = playlist("Friday", ["Alpha", "Bravo", "Charlie"])

      %{playlist: made, entries: entries}
    end

    test "it draws the tracks in the order that they play", %{conn: conn, playlist: made} do
      {:ok, view, _html} = live(conn, ~p"/playlists/#{made.id}")

      assert titles_on(view) == ["Alpha", "Bravo", "Charlie"]
    end

    test "every row holds a handle to drag", %{conn: conn, playlist: made, entries: entries} do
      {:ok, view, _html} = live(conn, ~p"/playlists/#{made.id}")

      assert has_element?(view, "#playlist-rows[phx-hook='DragToReorder']")

      for entry <- entries do
        assert has_element?(view, "#entry-#{entry.id}[data-row='#{entry.id}']")
        assert has_element?(view, "#drag-#{entry.id}[data-drag-handle]")
      end
    end

    test "a track that a person drags lands where they dropped it", %{
      conn: conn,
      playlist: made,
      entries: entries
    } do
      last = List.last(entries)

      {:ok, view, _html} = live(conn, ~p"/playlists/#{made.id}")

      render_hook(view, "move", %{"id" => last.id, "position" => 0})

      assert titles_on(view) == ["Charlie", "Alpha", "Bravo"]
    end

    test "a track that a person takes out goes", %{conn: conn, playlist: made, entries: entries} do
      [first | _rest] = entries

      {:ok, view, _html} = live(conn, ~p"/playlists/#{made.id}")

      view |> element("#remove-#{first.id}") |> render_click()

      assert titles_on(view) == ["Bravo", "Charlie"]
    end

    # A press on a row means "play this, and then the rest of the playlist".
    test "a press on a row keeps the rest of the playlist", %{conn: conn, playlist: made} do
      ids = Playback.playlist_item_ids!(made.id)
      second = Enum.at(ids, 1)

      {:ok, view, _html} = live(conn, ~p"/playlists/#{made.id}")

      render_click(view, "play", %{"id" => second})

      assert Playback.queue!() |> Enum.map(& &1.item_id) == ids
      assert %{item_id: ^second} = Playback.queue_playing!()
    end

    test "a person gives the playlist another name", %{conn: conn, playlist: made} do
      {:ok, view, _html} = live(conn, ~p"/playlists/#{made.id}")

      html = view |> form("#rename-form", %{"name" => "Saturday"}) |> render_submit()

      assert html =~ "That playlist is Saturday now"
      assert to_string(Playback.get_playlist!(made.id).name) == "Saturday"
    end

    # A playlist names an item and it does not own one, so the tracks stay.
    test "a person removes the playlist, and the tracks stay", %{conn: conn, playlist: made} do
      {:ok, view, _html} = live(conn, ~p"/playlists/#{made.id}")

      assert {:error, {:live_redirect, %{to: "/playlists"}}} =
               view |> element("#remove-playlist") |> render_click()

      assert Playback.list_playlists!() == []
      assert length(Playback.list_items!()) == 3
    end

    test "an address that names no playlist goes back to the list", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/playlists"}}} =
               live(conn, ~p"/playlists/#{Ash.UUID.generate()}")
    end
  end

  # **Nothing else asks for the picture of a track**, so a playlist of tracks asks for
  # each one. See `MyHiFiWeb.QueueLive`.
  describe "the pictures" do
    test "the page asks for the picture of each row", %{conn: conn} do
      made = Playback.create_playlist!("Friday")

      item =
        Playback.upsert_item!(%{
          source: "internet-radio",
          source_ref: "station-with-a-logo",
          title: "Delta",
          artwork_url: "https://station.test/logo.png"
        })

      {:ok, _entries} = Playback.add_to_playlist(made.id, [item.id])

      {:ok, _view, _html} = live(conn, ~p"/playlists/#{made.id}")

      assert_enqueued(
        worker: MyHiFi.Artwork.Worker,
        args: %{"url" => "https://station.test/logo.png"}
      )
    end
  end
end
