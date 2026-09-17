defmodule PiFi.DeviceUi.MenuTest do
  use PiFi.DataCase, async: false

  alias PiFi.DeviceUi.Menu
  alias PiFi.Playback
  alias PiFi.Source
  alias PiFi.Test.Stations

  setup do
    Playback.clear_queue!()
    on_exit(fn -> Playback.clear_queue!() end)

    :ok
  end

  defp titles(place), do: place |> Menu.level() |> Map.fetch!(:rows) |> Enum.map(& &1.title)

  defp row(place, title) do
    place |> Menu.level() |> Map.fetch!(:rows) |> Enum.find(&(&1.title == title))
  end

  defp item(title) do
    Playback.upsert_item!(%{
      source: "internet-radio",
      source_ref: "station-#{System.unique_integer([:positive])}",
      title: title
    })
  end

  describe "the root" do
    # **Now playing is the first row, because it is the way out.**
    test "it names the way out, each source in use, the lists and standby" do
      assert ["Now playing" | rest] = titles(:root)

      for module <- Source.enabled(), do: assert(module.title() in rest)

      assert "Playlists" in rest
      assert "Play queue" in rest
      assert "Standby" in rest
    end

    test "a source that a person took out of use is absent" do
      on_exit(fn -> Playback.enable_source(Source.InternetRadio, true) end)
      {:ok, _result} = Playback.enable_source(Source.InternetRadio, false)

      refute "Internet radio" in titles(:root)
    end

    test "the way out closes the menu, and standby acts on the device" do
      assert %{kind: :do, action: :close} = row(:root, "Now playing")
      assert %{kind: :do, action: :standby} = row(:root, "Standby")
    end
  end

  # **The source names its own branches, so the menu knows no source.**
  describe "a source" do
    test "it names the branches that the source names" do
      names = Enum.map(Source.InternetRadio.roots(), fn {name, _listing} -> name end)

      assert titles({:source, Source.InternetRadio}) == names
    end

    test "a branch of facets leads to the values of that key" do
      Stations.create(%{country_code: "NZ", title: "RNZ National"})
      Stations.create(%{country_code: "AU", title: "ABC Sydney"})

      assert titles({:branch, Source.InternetRadio, "Countries"}) == ["AU", "NZ"]
    end

    test "a facet leads to the items that carry it" do
      Stations.create(%{country_code: "NZ", title: "RNZ National"})
      Stations.create(%{country_code: "AU", title: "ABC Sydney"})

      assert titles({:facet, Source.InternetRadio, "NZ"}) == ["RNZ National"]
    end

    # A press on a track plays the level that it is in, so the row carries the
    # identifiers of the level and the place of the row among them.
    test "a track plays the level that it is in" do
      Stations.create(%{country_code: "NZ", title: "Alpha"})
      Stations.create(%{country_code: "NZ", title: "Bravo"})

      assert %{kind: :play, action: {:play, ids, index}} =
               row({:facet, Source.InternetRadio, "NZ"}, "Bravo")

      assert length(ids) == 2
      assert index == 1
    end

    test "a branch that the source does not name gives the root" do
      assert Menu.level({:branch, Source.InternetRadio, "Nothing"}).place == :root
    end
  end

  describe "a container" do
    setup do
      artist =
        Playback.upsert_item!(%{
          source: "jellyfin",
          source_ref: "artist-1",
          kind: :container,
          title: "Massive Attack"
        })

      album =
        Playback.upsert_item!(%{
          source: "jellyfin",
          source_ref: "album-1",
          kind: :container,
          title: "Mezzanine",
          parent_id: artist.id
        })

      track =
        Playback.upsert_item!(%{
          source: "jellyfin",
          source_ref: "track-1",
          kind: :track,
          title: "Angel",
          parent_id: album.id,
          number: 1
        })

      %{artist: artist, album: album, track: track}
    end

    test "it opens into what it holds", %{artist: artist, album: album} do
      assert titles({:container, Source.Jellyfin, artist.id}) == ["Mezzanine"]
      assert titles({:container, Source.Jellyfin, album.id}) == ["Angel"]
    end

    test "a container row leads to the container", %{artist: artist, album: album} do
      assert %{kind: :open, action: {:open, {:container, Source.Jellyfin, id}}} =
               row({:container, Source.Jellyfin, artist.id}, "Mezzanine")

      assert id == album.id
    end

    # An identifier of one source cannot open under another one.
    test "a container of another source gives the root", %{album: album} do
      assert Menu.level({:container, Source.InternetRadio, album.id}).place == :root
    end
  end

  describe "the playlists" do
    test "it names each playlist and how many tracks it carries" do
      made = Playback.create_playlist!("Friday")
      {:ok, _entries} = Playback.add_to_playlist(made.id, [item("Alpha").id])

      assert titles(:playlists) == ["Friday"]
      assert %{subtitle: "1 track", action: {:open, {:playlist, _id}}} = row(:playlists, "Friday")
    end

    test "a playlist opens into its tracks, in the order that they play" do
      made = Playback.create_playlist!("Friday")
      ids = Enum.map(["Alpha", "Bravo"], &item(&1).id)
      {:ok, _entries} = Playback.add_to_playlist(made.id, ids)

      assert titles({:playlist, made.id}) == ["Alpha", "Bravo"]
      assert %{kind: :play, action: {:play, ^ids, 1}} = row({:playlist, made.id}, "Bravo")
    end

    test "a playlist that is gone gives the root" do
      assert Menu.level({:playlist, Ash.UUID.generate()}).place == :root
    end
  end

  describe "the queue" do
    test "it names the rows in the order that they play" do
      ids = Enum.map(["Alpha", "Bravo"], &item(&1).id)
      {:ok, _rows} = Playback.replace_queue(ids, %{playing_index: 0})

      assert titles(:queue) == ["Alpha", "Bravo"]
      assert %{kind: :play, action: {:play, ^ids, 0}} = row(:queue, "Alpha")
    end

    test "an empty queue names nothing" do
      assert titles(:queue) == []
    end
  end
end
