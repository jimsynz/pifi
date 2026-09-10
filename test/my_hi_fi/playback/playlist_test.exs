defmodule MyHiFi.Playback.PlaylistTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Playback

  defp item(title, source \\ "internet-radio") do
    Playback.upsert_item!(%{
      source: source,
      source_ref: "#{source}-#{System.unique_integer([:positive])}",
      title: title
    })
  end

  defp playlist(name), do: Playback.create_playlist!(name)

  defp titles(playlist) do
    playlist.id
    |> Playback.playlist_entries!(load: [:item])
    |> Enum.map(& &1.item.title)
  end

  defp places(playlist) do
    playlist.id
    |> Playback.playlist_entries!()
    |> Enum.map(& &1.position)
  end

  describe "making one" do
    test "a playlist begins with a name and nothing in it" do
      made = playlist("Friday")

      assert to_string(made.name) == "Friday"
      assert Playback.playlist_entries!(made.id) == []
    end

    test "a second playlist of one name gives an error" do
      playlist("Friday")

      assert {:error, _reason} = Playback.create_playlist("Friday")
    end

    test "a name of no characters gives an error" do
      assert {:error, _reason} = Playback.create_playlist("")
      assert {:error, _reason} = Playback.create_playlist("   ")
    end

    test "a person gives a playlist another name" do
      made = playlist("Friday")

      assert {:ok, renamed} = Playback.rename_playlist(made, "Saturday")
      assert to_string(renamed.name) == "Saturday"
    end

    # A playlist reads in the order of the letters, and not in the order of the bytes.
    # SQLite compares text byte by byte, so a plain string would put every capital in
    # front of every small letter.
    test "the list of playlists reads in the order of the letters" do
      playlist("zeppelin")
      playlist("Aotearoa")
      playlist("mixtape")

      names = Playback.list_playlists!() |> Enum.map(&to_string(&1.name))

      assert names == ["Aotearoa", "mixtape", "zeppelin"]
    end
  end

  describe "putting tracks in one" do
    test "a track goes on the end, and the order is the order that arrived" do
      made = playlist("Friday")
      alpha = item("Alpha")
      bravo = item("Bravo")

      {:ok, _entries} = Playback.add_to_playlist(made.id, [alpha.id, bravo.id])
      {:ok, _entries} = Playback.add_to_playlist(made.id, [alpha.id])

      assert titles(made) == ["Alpha", "Bravo", "Alpha"]
      assert places(made) == [0, 1, 2]
    end

    # **A playlist takes a track of any source.** This is the extra credit of the
    # issue, and `MyHiFi.Playback.Item` is what gives it: one table holds a station, an
    # episode and a song.
    test "one playlist takes a track of each source" do
      made = playlist("Friday")
      station = item("RNZ National", "internet-radio")
      episode = item("Episode 1", "podcasts")
      song = item("Teardrop", "jellyfin")

      {:ok, _entries} = Playback.add_to_playlist(made.id, [station.id, episode.id, song.id])

      assert titles(made) == ["RNZ National", "Episode 1", "Teardrop"]
    end

    test "it counts what it carries" do
      made = playlist("Friday")
      {:ok, _entries} = Playback.add_to_playlist(made.id, [item("Alpha").id, item("Bravo").id])

      assert [read] = Playback.list_playlists!(load: [:entry_count])
      assert read.entry_count == 2
    end
  end

  describe "changing one" do
    setup do
      made = playlist("Friday")
      ids = Enum.map(["Alpha", "Bravo", "Charlie", "Delta"], &item(&1).id)
      {:ok, entries} = Playback.add_to_playlist(made.id, ids)

      %{playlist: made, entries: Enum.sort_by(entries, & &1.position)}
    end

    test "a track that a person drags lands where they dropped it", %{
      playlist: made,
      entries: entries
    } do
      last = List.last(entries)

      {:ok, _moved} = Playback.reorder_playlist_entry(last.id, 1)

      assert titles(made) == ["Alpha", "Delta", "Bravo", "Charlie"]
      assert places(made) == [0, 1, 2, 3]
    end

    # A place outside the playlist is clamped, so a drag above the first row leaves it
    # where it is.
    test "a place outside the playlist lands on the nearest end", %{
      playlist: made,
      entries: [first | _rest]
    } do
      {:ok, _moved} = Playback.reorder_playlist_entry(first.id, -5)
      assert titles(made) == ["Alpha", "Bravo", "Charlie", "Delta"]

      {:ok, _moved} = Playback.reorder_playlist_entry(first.id, 99)
      assert titles(made) == ["Bravo", "Charlie", "Delta", "Alpha"]
    end

    test "a track that a person takes out goes, and the rest close around it", %{
      playlist: made,
      entries: entries
    } do
      second = Enum.at(entries, 1)

      {:ok, _removed} = Playback.remove_playlist_entry(second.id)

      assert titles(made) == ["Alpha", "Charlie", "Delta"]
      assert places(made) == [0, 1, 2]
    end

    test "the identifiers read in the order that they play", %{playlist: made} do
      ids = Playback.playlist_item_ids!(made.id)

      assert length(ids) == 4

      titles = Enum.map(ids, &Playback.get_item!(&1).title)
      assert titles == ["Alpha", "Bravo", "Charlie", "Delta"]
    end

    # A playlist names an item and it does not own one, so the track stays.
    test "a playlist that goes leaves its tracks", %{playlist: made} do
      titles = titles(made)

      :ok = Playback.destroy_playlist(made)

      assert Playback.list_playlists!() == []
      assert Playback.playlist_entries!(made.id) == []

      held = Playback.list_items!() |> Enum.map(& &1.title)
      for title <- titles, do: assert(title in held)
    end

    # **A track that a sync removes takes its entries with it.** A service that no
    # longer carries a song must leave no row of a playlist that draws nothing.
    test "a track that goes leaves no entry behind", %{playlist: made, entries: entries} do
      [first | _rest] = entries

      Playback.get_item!(first.item_id) |> Ash.destroy!()

      assert titles(made) == ["Bravo", "Charlie", "Delta"]
    end
  end
end
