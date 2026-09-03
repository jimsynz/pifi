defmodule MyHiFi.Jellyfin.SyncTest do
  use MyHiFi.DataCase, async: false
  use Oban.Testing, repo: MyHiFi.Repo

  import Ash.Expr

  require Ash.Query

  alias MyHiFi.Event
  alias MyHiFi.Jellyfin
  alias MyHiFi.Jellyfin.Fill
  alias MyHiFi.Jellyfin.Server
  alias MyHiFi.Playback.Item
  alias MyHiFi.Settings
  alias MyHiFi.Source

  setup do
    Application.put_env(:my_hi_fi, Server, plug: {Req.Test, Server}, retry: false)
    on_exit(fn -> Application.delete_env(:my_hi_fi, Server) end)

    Settings.put!(Server.address_setting(), "http://jellyfin.test")
    Settings.put!(Server.token_setting(), "THETOKEN")
    Settings.put!(Server.user_setting(), "THEUSER")

    :ok
  end

  defp artist(number) do
    %{"Id" => "artist-#{number}", "Name" => "Artist #{number}"}
  end

  defp album(number, artist) do
    %{
      "Id" => "album-#{number}",
      "Name" => "Album #{number}",
      "AlbumArtist" => "Artist #{artist}",
      "AlbumArtists" => [%{"Id" => "artist-#{artist}", "Name" => "Artist #{artist}"}]
    }
  end

  defp track(number, album) do
    %{
      "Id" => "track-#{number}",
      "Name" => "Track #{number}",
      "Album" => "Album #{album}",
      "AlbumId" => "album-#{album}",
      "Container" => "flac",
      "RunTimeTicks" => 2_000_000_000,
      "MediaSources" => [%{"Size" => 30_000_000}]
    }
  end

  # The server answers each listing from its own list, and it reads `StartIndex` and
  # `Limit` in the way that Jellyfin does, so a test can measure the paging.
  defp stub_library(library) do
    test = self()

    Req.Test.stub(Server, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test, {:request, conn.params["IncludeItemTypes"], conn.params["StartIndex"]})

      items = Map.get(library, conn.params["IncludeItemTypes"], [])
      start = String.to_integer(conn.params["StartIndex"])
      limit = String.to_integer(conn.params["Limit"])

      Req.Test.json(conn, %{
        "Items" => items |> Enum.drop(start) |> Enum.take(limit),
        "TotalRecordCount" => length(items)
      })
    end)
  end

  defp all_items do
    Item
    |> Ash.Query.filter(source == ^Fill.source())
    |> Ash.Query.sort(title: :asc)
    |> Ash.read!()
  end

  defp cache_jobs, do: all_enqueued(worker: MyHiFi.Playback.Item.Workers.CacheAudio)

  defp items(filter) do
    Item
    |> Ash.Query.filter(source == ^Fill.source())
    |> Ash.Query.filter(^filter)
    |> Ash.Query.sort(title: :asc)
    |> Ash.read!()
  end

  describe "sync_library" do
    test "it writes the artists, the albums and the tracks as one tree" do
      stub_library(%{
        "MusicArtist" => [artist(1)],
        "MusicAlbum" => [album(1, 1)],
        "Audio" => [track(1, 1), track(2, 1)]
      })

      assert {:ok, report} = Jellyfin.sync_library()

      assert report == %{artists: 1, albums: 1, tracks: 2, removed: 0, skipped?: false}

      assert [artist] = items(expr(kind == :container and is_nil(parent_id)))
      assert artist.title == "Artist 1"

      assert [album] = items(expr(kind == :container and not is_nil(parent_id)))
      assert album.title == "Album 1"
      assert album.parent_id == artist.id

      assert tracks = items(expr(kind == :track))
      assert Enum.map(tracks, & &1.title) == ["Track 1", "Track 2"]
      assert Enum.all?(tracks, &(&1.parent_id == album.id))
    end

    # `MyHiFi.Playback.Item` decides which favourites read on to the card, and it must
    # decide with no service to ask.
    test "a track holds what the player and the card need" do
      stub_library(%{
        "MusicArtist" => [artist(1)],
        "MusicAlbum" => [album(1, 1)],
        "Audio" => [track(1, 1)]
      })

      Jellyfin.sync_library!()

      assert [item] = items(expr(kind == :track))

      assert item.transport == :download
      assert item.container_format == :none
      assert item.format == :flac
      assert item.duration_ms == 200_000
      assert item.byte_size == 30_000_000
      # A song is not an episode. See `MyHiFi.Playback.FavouriteAudio`.
      assert item.keeps_place? == false
      assert item.live? == false
      # The address carries the token of the moment, so `resolve/1` builds it.
      assert item.url == nil
    end

    # A library holds tens of thousands of tracks, and this board holds 363.9 MB.
    test "it reads a listing that is larger than one page, one page at a time" do
      tracks = Enum.map(1..(Server.page_size() + 3), &track(&1, 1))

      stub_library(%{
        "MusicArtist" => [artist(1)],
        "MusicAlbum" => [album(1, 1)],
        "Audio" => tracks
      })

      assert {:ok, %{tracks: written}} = Jellyfin.sync_library()

      assert written == Server.page_size() + 3
      assert length(items(expr(kind == :track))) == Server.page_size() + 3

      assert_receive {:request, "Audio", "0"}
      assert_receive {:request, "Audio", start}
      assert start == to_string(Server.page_size())
    end

    test "a second read writes no second row, and it keeps what a person did" do
      stub_library(%{
        "MusicArtist" => [artist(1)],
        "MusicAlbum" => [album(1, 1)],
        "Audio" => [track(1, 1)]
      })

      Jellyfin.sync_library!()
      [first] = items(expr(kind == :track))
      {:ok, _item} = MyHiFi.Playback.set_favourite(first)

      Jellyfin.sync_library!()

      assert [again] = items(expr(kind == :track))
      assert again.id == first.id
      assert again.favourite? == true
    end

    # An album whose artist the server does not name must not stand beside the artists
    # in that branch.
    test "an album with no artist goes under one container that this source keeps" do
      stub_library(%{
        "MusicArtist" => [],
        "MusicAlbum" => [%{"Id" => "album-1", "Name" => "A compilation"}],
        "Audio" => []
      })

      Jellyfin.sync_library!()

      assert [unknown] = items(expr(kind == :container and is_nil(parent_id)))
      assert unknown.title == "Unknown artist"
      assert unknown.source_ref == Fill.unknown_artist_ref()

      assert [album] = items(expr(kind == :container and not is_nil(parent_id)))
      assert album.parent_id == unknown.id
    end

    test "a page that shows this source reads it again when the read finishes" do
      stub_library(%{"MusicArtist" => [artist(1)], "MusicAlbum" => [], "Audio" => []})

      Event.subscribe(:source)

      Jellyfin.sync_library!()

      assert_receive %Event.Source.Changed{source: Source.Jellyfin, ref: :library}
    end

    # A library of one album, so a later read of a library with none of it removes it.
    defp sync_one_album do
      stub_library(%{
        "MusicArtist" => [artist(1)],
        "MusicAlbum" => [album(1, 1)],
        "Audio" => [track(1, 1), track(2, 1)]
      })

      Jellyfin.sync_library!()
    end

    test "a read that finishes removes what the server no longer holds" do
      sync_one_album()
      assert length(all_items()) == 4

      # The server now holds a different album, and nothing of the first one.
      stub_library(%{
        "MusicArtist" => [artist(2)],
        "MusicAlbum" => [album(2, 2)],
        "Audio" => [track(3, 2)]
      })

      assert {:ok, report} = Jellyfin.sync_library()

      assert report.removed == 4

      assert Enum.map(all_items(), & &1.source_ref) |> Enum.sort() ==
               ["album-2", "artist-2", "track-3"]
    end

    # The one rule that makes the removal safe. A read that stops half way has seen no
    # track, so a remover that ran then would empty the catalogue.
    test "a read that fails removes nothing" do
      sync_one_album()
      before = Enum.map(all_items(), & &1.id) |> Enum.sort()

      Req.Test.stub(Server, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, _reason} = Jellyfin.sync_library()
      assert Enum.map(all_items(), & &1.id) |> Enum.sort() == before
    end

    test "a read that gives up half way removes nothing" do
      sync_one_album()
      before = Enum.map(all_items(), & &1.id) |> Enum.sort()

      # The artists arrive, and the albums do not.
      Req.Test.stub(Server, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.params["IncludeItemTypes"] do
          "MusicArtist" ->
            Req.Test.json(conn, %{"Items" => [artist(1)], "TotalRecordCount" => 1})

          _other ->
            Req.Test.transport_error(conn, :econnrefused)
        end
      end)

      assert {:error, _reason} = Jellyfin.sync_library()
      assert Enum.map(all_items(), & &1.id) |> Enum.sort() == before
    end

    # `MyHiFi.Jellyfin.Fill` writes this container for an album that names no artist,
    # and it writes it by another path. A row of it with no stamp would take every such
    # album away with it.
    test "the container of an album with no artist stays" do
      stub_library(%{
        "MusicArtist" => [],
        "MusicAlbum" => [Map.drop(album(1, 1), ["AlbumArtist", "AlbumArtists"])],
        "Audio" => []
      })

      Jellyfin.sync_library!()
      assert {:ok, report} = Jellyfin.sync_library()

      assert report.removed == 0

      refs = Enum.map(all_items(), & &1.source_ref) |> Enum.sort()
      assert Fill.unknown_artist_ref() in refs
      assert "album-1" in refs
    end

    # A person keeps their mark everywhere else, and not here: the catalogue follows
    # the server.
    test "a mark does not hold a row back" do
      sync_one_album()
      [one | _rest] = items(expr(kind == :track))
      {:ok, _marked} = MyHiFi.Playback.set_favourite(one)

      stub_library(%{"MusicArtist" => [], "MusicAlbum" => [], "Audio" => []})

      assert {:ok, _report} = Jellyfin.sync_library()
      assert all_items() == []
    end

    test "a person who took this source out of use asks the server nothing" do
      Req.Test.stub(Server, fn _conn -> raise "the server must not be asked" end)
      Source.enable(Source.Jellyfin, false)
      on_exit(fn -> Source.enable(Source.Jellyfin, true) end)

      assert {:ok, %{skipped?: true}} = Jellyfin.sync_library()
    end

    test "a device with no link asks nothing" do
      Req.Test.stub(Server, fn _conn -> raise "the server must not be asked" end)
      Settings.delete!(Settings.fetch!(Server.token_setting()))

      assert {:ok, %{skipped?: true}} = Jellyfin.sync_library()
    end

    test "a server that does not answer leaves the catalogue as it stands" do
      Req.Test.stub(Server, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, _reason} = Jellyfin.sync_library()
      assert all_items() == []
    end
  end

  # A mark asks for the audio at once, and a device that held no network at that
  # moment reads nothing. This is the run that covers it.
  describe "cache_favourites" do
    setup do
      stub_library(%{
        "MusicArtist" => [artist(1)],
        "MusicAlbum" => [album(1, 1)],
        "Audio" => [track(1, 1)]
      })

      Jellyfin.sync_library!()

      :ok
    end

    # The mark itself puts one job in the queue, so this counts what the run adds.
    test "it puts one job in the queue for each marked item" do
      [one] = items(expr(kind == :track))
      {:ok, _item} = MyHiFi.Playback.set_favourite(one)

      before = length(cache_jobs())

      assert {:ok, 1} = Jellyfin.cache_favourites()

      assert length(cache_jobs()) == before + 1
    end

    test "a device that marked nothing asks for nothing" do
      assert {:ok, 0} = Jellyfin.cache_favourites()

      assert cache_jobs() == []
    end

    test "a person who took this source out of use asks for nothing" do
      [one] = items(expr(kind == :track))
      {:ok, _item} = MyHiFi.Playback.set_favourite(one)

      Source.enable(Source.Jellyfin, false)
      on_exit(fn -> Source.enable(Source.Jellyfin, true) end)

      assert {:ok, 0} = Jellyfin.cache_favourites()
    end

    test "a device with no link asks for nothing" do
      [one] = items(expr(kind == :track))
      {:ok, _item} = MyHiFi.Playback.set_favourite(one)
      Settings.delete!(Settings.fetch!(Server.token_setting()))

      assert {:ok, 0} = Jellyfin.cache_favourites()
    end
  end
end
