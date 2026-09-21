defmodule PiFi.Plex.SyncTest do
  use PiFi.DataCase, async: false
  use Oban.Testing, repo: PiFi.Repo

  require Ash.Query

  alias PiFi.Event
  alias PiFi.Playback
  alias PiFi.Playback.Item
  alias PiFi.Plex
  alias PiFi.Plex.Fill
  alias PiFi.Plex.Server
  alias PiFi.Plex.Sync.Checkpoint
  alias PiFi.Plex.Sync.Survey
  alias PiFi.Settings
  alias PiFi.Source

  setup do
    Application.put_env(:pifi, Server, plug: {Req.Test, Server}, retry: false)
    on_exit(fn -> Application.delete_env(:pifi, Server) end)

    Settings.put!(Server.address_setting(), "http://plex.test:32400")
    Settings.put!(Server.token_setting(), "THETOKEN")

    :ok
  end

  defp artist(number) do
    %{
      "ratingKey" => "artist-#{number}",
      "title" => "Artist #{number}",
      "summary" => "The life of artist #{number}."
    }
  end

  defp album(number, artist, genres \\ [], studio \\ nil) do
    %{
      "ratingKey" => "album-#{number}",
      "title" => "Album #{number}",
      "parentRatingKey" => "artist-#{artist}",
      "parentTitle" => "Artist #{artist}",
      "summary" => "A review of album #{number}.",
      "year" => 1998,
      "Genre" => Enum.map(genres, &%{"tag" => &1}),
      "studio" => studio
    }
  end

  defp track(number, album) do
    %{
      "ratingKey" => "track-#{number}",
      "title" => "Track #{number}",
      "parentRatingKey" => "album-#{album}",
      "grandparentTitle" => "Artist 1",
      "duration" => 200_000,
      "Media" => [
        %{
          "audioCodec" => "flac",
          "container" => "flac",
          "Part" => [%{"key" => "/library/parts/#{number}/1/file.flac", "size" => 30_000_000}]
        }
      ]
    }
  end

  # The server answers `/library/sections` from the keys of `library`, and each listing
  # from its own list. It reads the two paging headers in the way that Plex does, so a
  # test can measure the paging.
  #
  # `library` is `%{section => %{type => [item]}}`.
  defp stub_library(library), do: stub_library(library, %{})

  # `playlists` is `%{ref => %{title: _, updated_at: _, refs: [track ref]}}`, and a
  # server with none answers an empty list rather than a 404.
  defp stub_library(library, playlists) do
    test = self()

    Req.Test.stub(Server, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.request_path do
        "/playlists" ->
          send(test, {:request, :playlists, nil, nil})

          Req.Test.json(conn, %{
            "MediaContainer" => %{
              "Metadata" =>
                Enum.map(playlists, fn {ref, playlist} ->
                  %{
                    "ratingKey" => ref,
                    "title" => playlist.title,
                    "updatedAt" => playlist[:updated_at]
                  }
                end)
            }
          })

        "/playlists/" <> rest ->
          ref = rest |> String.split("/") |> List.first()
          refs = playlists |> Map.get(ref, %{}) |> Map.get(:refs, [])
          start = header(conn, "x-plex-container-start")
          size = header(conn, "x-plex-container-size")

          send(test, {:request, :playlist_items, ref, start})

          Req.Test.json(conn, %{
            "MediaContainer" => %{
              "Metadata" =>
                refs
                |> Enum.drop(start)
                |> Enum.take(size)
                |> Enum.map(&%{"ratingKey" => &1}),
              "totalSize" => length(refs)
            }
          })

        "/library/sections" ->
          send(test, {:request, :sections, nil, nil})

          Req.Test.json(conn, %{
            "MediaContainer" => %{
              "Directory" =>
                Enum.map(Map.keys(library), &%{"key" => &1, "type" => "artist", "title" => &1})
            }
          })

        path ->
          section = path |> String.split("/") |> Enum.at(3)
          type = conn.params["type"]
          start = header(conn, "x-plex-container-start")
          size = header(conn, "x-plex-container-size")

          send(test, {:request, :page, {section, type}, start})

          # **The listing of a test is in the order that things were added**, so the
          # newest is last. A survey asks for `addedAt:desc` and reads until it meets
          # something it knows, and a stub that ignored the sort would hand it the
          # oldest first and it would stop at once. See `PiFi.Plex.Sync.Survey`.
          items =
            library
            |> Map.get(section, %{})
            |> Map.get(type, [])
            |> newest_first(conn.params["sort"])

          Req.Test.json(conn, %{
            "MediaContainer" => %{
              "Metadata" => items |> Enum.drop(start) |> Enum.take(size),
              "totalSize" => length(items)
            }
          })
      end
    end)
  end

  defp drain_requests do
    receive do
      {:request, _what, _which, _start} -> drain_requests()
    after
      0 -> :ok
    end
  end

  # A survey asks for one entry to learn a count, and a page to reach something known.
  # A walk of the library asks for pages of 50.
  defp pages_read(counted \\ 0) do
    receive do
      {:request, :page, _which, _start} -> pages_read(counted + 1)
      {:request, _what, _which, _start} -> pages_read(counted)
    after
      0 -> counted
    end
  end

  defp newest_first(items, "addedAt:desc"), do: Enum.reverse(items)
  defp newest_first(items, _sort), do: items

  defp header(conn, name) do
    conn.req_headers |> Map.new() |> Map.fetch!(name) |> String.to_integer()
  end

  # Plex names each kind of thing in a library by a number.
  defp artists, do: "8"
  defp albums, do: "9"
  defp tracks, do: "10"

  defp one_section(artists, albums, tracks) do
    %{"3" => %{artists() => artists, albums() => albums, tracks() => tracks}}
  end

  defp all_items do
    Item
    |> Ash.Query.filter(source == ^Fill.source())
    |> Ash.Query.sort(title: :asc)
    |> Ash.read!()
  end

  defp items_of(kind) do
    Item
    |> Ash.Query.filter(source == ^Fill.source() and kind == ^kind)
    |> Ash.Query.sort(title: :asc)
    |> Ash.read!()
  end

  defp playlists_here do
    Playback.list_playlists!() |> Enum.sort_by(&to_string(&1.name))
  end

  defp entry_refs(playlist) do
    playlist.id
    |> Playback.playlist_entries!(load: [:item])
    |> Enum.map(& &1.item.source_ref)
  end

  # **A playlist belongs to the server and not to a library section**, and it names
  # tracks that the track pass has already written, so it reads last and once.
  describe "the playlists of the server" do
    test "it writes one row for each, with the tracks in the order the server gave" do
      stub_library(
        one_section([artist(1)], [album(1, 1)], [track(1, 1), track(2, 1)]),
        %{"p1" => %{title: "Road trip", refs: ["track-2", "track-1"]}}
      )

      assert {:ok, counts} = Plex.sync_library()
      assert counts.playlists == 1

      assert [playlist] = playlists_here()
      assert to_string(playlist.name) == "Road trip"
      assert playlist.source == Fill.source()
      assert playlist.source_ref == "p1"
      refute Playback.Playlist.mine?(playlist)

      assert entry_refs(playlist) == ["track-2", "track-1"]
    end

    # `PiFi.Playback.PlaylistEntry` says it in as many words: a track goes in twice if
    # a person asks twice. This is the case a facet could never have represented.
    test "a track that a person put in twice is in it twice" do
      stub_library(
        one_section([artist(1)], [album(1, 1)], [track(1, 1)]),
        %{"p1" => %{title: "On repeat", refs: ["track-1", "track-1", "track-1"]}}
      )

      assert {:ok, _counts} = Plex.sync_library()

      assert [playlist] = playlists_here()
      assert entry_refs(playlist) == ["track-1", "track-1", "track-1"]
    end

    # A person removed it on the server, so it goes here. The tracks stay: a playlist
    # names an item and it does not own one.
    test "one that the server no longer has goes, and its tracks stay" do
      library = one_section([artist(1)], [album(1, 1)], [track(1, 1)])

      stub_library(library, %{"p1" => %{title: "Gone soon", refs: ["track-1"]}})
      assert {:ok, _counts} = Plex.sync_library()
      assert length(playlists_here()) == 1

      stub_library(library, %{})
      assert {:ok, counts} = Plex.sync_library()

      assert counts.forgotten == 1
      assert playlists_here() == []
      assert length(items_of(:track)) == 1
    end

    # **An SD card has a finite number of writes**, and most reads find a playlist that
    # nobody touched, so the tracks of one are read only when the server says it moved.
    test "one that did not change is not read again" do
      library = one_section([artist(1)], [album(1, 1)], [track(1, 1)])
      playlists = %{"p1" => %{title: "Steady", updated_at: 1_700_000_000, refs: ["track-1"]}}

      stub_library(library, playlists)
      assert {:ok, _counts} = Plex.sync_library()
      assert_received {:request, :playlist_items, "p1", _start}

      stub_library(library, playlists)
      assert {:ok, _counts} = Plex.sync_library()

      assert_received {:request, :playlists, _ref, _start}
      refute_received {:request, :playlist_items, "p1", _start}
    end

    test "one that changed is read again" do
      library = one_section([artist(1)], [album(1, 1)], [track(1, 1), track(2, 1)])

      stub_library(library, %{
        "p1" => %{title: "Moving", updated_at: 1_700_000_000, refs: ["track-1"]}
      })

      assert {:ok, _counts} = Plex.sync_library()
      assert entry_refs(hd(playlists_here())) == ["track-1"]

      stub_library(library, %{
        "p1" => %{title: "Moving", updated_at: 1_700_000_900, refs: ["track-1", "track-2"]}
      })

      assert {:ok, _counts} = Plex.sync_library()

      assert entry_refs(hd(playlists_here())) == ["track-1", "track-2"]
    end

    # A server lets a person rename a playlist, and the row follows rather than making
    # a second one, because the reference identifies it and the name does not.
    test "a rename on the server renames the row" do
      library = one_section([artist(1)], [album(1, 1)], [track(1, 1)])

      stub_library(library, %{"p1" => %{title: "Old name", refs: ["track-1"]}})
      assert {:ok, _counts} = Plex.sync_library()

      stub_library(library, %{"p1" => %{title: "New name", refs: ["track-1"]}})
      assert {:ok, _counts} = Plex.sync_library()

      assert [playlist] = playlists_here()
      assert to_string(playlist.name) == "New name"
    end

    test "a playlist that a person made here is left alone" do
      {:ok, mine} = Playback.create_playlist("Mine")

      stub_library(one_section([artist(1)], [album(1, 1)], [track(1, 1)]), %{})
      assert {:ok, counts} = Plex.sync_library()

      assert counts.forgotten == 0
      assert [kept] = playlists_here()
      assert kept.id == mine.id
      assert Playback.Playlist.mine?(kept)
    end

    # A read that stopped part way through the library leaves tracks missing. A row
    # that claimed the moment anyway would be skipped by every later read and stay
    # short for ever.
    test "one whose tracks this device has not read yet is read again next time" do
      stub_library(
        one_section([artist(1)], [album(1, 1)], [track(1, 1)]),
        %{
          "p1" => %{title: "Partly here", updated_at: 1_700_000_000, refs: ["track-1", "track-9"]}
        }
      )

      assert {:ok, _counts} = Plex.sync_library()

      assert [playlist] = playlists_here()
      assert entry_refs(playlist) == ["track-1"]
      assert playlist.source_updated_at == nil

      stub_library(
        one_section([artist(1)], [album(1, 1)], [track(1, 1), track(9, 1)]),
        %{
          "p1" => %{title: "Partly here", updated_at: 1_700_000_000, refs: ["track-1", "track-9"]}
        }
      )

      assert {:ok, _counts} = Plex.sync_library()

      assert entry_refs(hd(playlists_here())) == ["track-1", "track-9"]
    end
  end

  # **A read of a whole library is 80 minutes and tens of thousands of writes**, and it
  # ran every day whether a person had added a record or not. These cover the three
  # answers of `PiFi.Plex.Sync.Survey` and the one thing it must never get wrong, which
  # is removing a library that is still there.
  describe "a library that a person did not change" do
    setup do
      # The whole read happens on a clock of its own, and these tests are about what
      # happens between two of them.
      on_exit(fn ->
        case Settings.fetch("plex.library.whole_read_at") do
          {:ok, setting} -> Settings.delete!(setting)
          {:error, _reason} -> :ok
        end
      end)

      :ok
    end

    test "is read once and then left alone" do
      library = one_section([artist(1)], [album(1, 1)], [track(1, 1)])

      stub_library(library)
      assert {:ok, first} = Plex.sync_library()
      assert first.tracks == 1

      stub_library(library)
      assert {:ok, second} = Plex.sync_library()

      assert second.artists == 0
      assert second.albums == 0
      assert second.tracks == 0
      refute second.skipped?

      # Everything is still here. A survey that removed what it did not read would have
      # emptied the catalogue.
      assert length(items_of(:track)) == 1
      assert second.removed == 0
    end

    # The whole point: a quiet library costs a handful of requests and no pages at all.
    test "costs no page of any listing" do
      library = one_section([artist(1)], [album(1, 1)], [track(1, 1)])

      stub_library(library)
      assert {:ok, _first} = Plex.sync_library()

      stub_library(library)
      drain_requests()
      assert {:ok, _second} = Plex.sync_library()

      # A survey reads one entry of each kind to learn the count, and one page of each
      # to reach something it knows. Nothing walks the library.
      assert pages_read() <= length(Survey.kinds()) * 2
    end
  end

  describe "a library that gained a record" do
    setup do
      on_exit(fn ->
        case Settings.fetch("plex.library.whole_read_at") do
          {:ok, setting} -> Settings.delete!(setting)
          {:error, _reason} -> :ok
        end
      end)

      :ok
    end

    test "writes the new one and leaves the rest where they are" do
      stub_library(one_section([artist(1)], [album(1, 1)], [track(1, 1)]))
      assert {:ok, _first} = Plex.sync_library()

      stub_library(one_section([artist(1)], [album(1, 1)], [track(1, 1), track(2, 1)]))
      assert {:ok, second} = Plex.sync_library()

      assert second.tracks == 1
      assert second.removed == 0
      assert length(items_of(:track)) == 2
    end
  end

  # **This is the one a survey must never get wrong.** A count that came back smaller
  # than the card holds means something went, and only a whole read can say what.
  describe "a library that lost a record" do
    setup do
      on_exit(fn ->
        case Settings.fetch("plex.library.whole_read_at") do
          {:ok, setting} -> Settings.delete!(setting)
          {:error, _reason} -> :ok
        end
      end)

      :ok
    end

    test "is read in full, and the one that went is removed" do
      stub_library(one_section([artist(1)], [album(1, 1)], [track(1, 1), track(2, 1)]))
      assert {:ok, _first} = Plex.sync_library()
      assert length(items_of(:track)) == 2

      stub_library(one_section([artist(1)], [album(1, 1)], [track(1, 1)]))
      assert {:ok, second} = Plex.sync_library()

      assert second.removed >= 1
      assert length(items_of(:track)) == 1
    end
  end

  describe "sync_library" do
    test "it writes the artists, the albums and the tracks of the server" do
      stub_library(one_section([artist(1)], [album(1, 1)], [track(1, 1)]))

      assert {:ok, counts} = Plex.sync_library()

      assert counts.artists == 1
      assert counts.albums == 1
      assert counts.tracks == 1
      refute counts.skipped?

      assert length(all_items()) == 3
    end

    # **The genres arrive with the album, so a read asks the server for nothing more.**
    # A genre becomes a facet, in the way that a country of a station does, and the
    # Genres branch is then a plain read of the facets.
    test "the genres of an album become facets of it" do
      stub_library(one_section([artist(1)], [album(1, 1, ["Rap", "Trip Hop"])], []))

      assert {:ok, _counts} = Plex.sync_library()

      [album] = Item |> Ash.Query.filter(source_ref == "album-1") |> Ash.read!(load: [:facets])

      assert Enum.map(album.facets, &to_string(&1.value.value)) |> Enum.sort() ==
               ["Rap", "Trip Hop"]

      assert Enum.map(album.facets, & &1.key) |> Enum.uniq() == [Fill.genre_key()]
    end

    # **The key names the source, so two libraries that both hold `Rock` hold two
    # facets.** One shared key would count the albums of both libraries on one row.
    test "the key of a genre names this source" do
      assert Fill.genre_key() == "plex-genre"
    end

    test "an album that names no genre writes no facet" do
      stub_library(one_section([artist(1)], [album(1, 1)], []))

      assert {:ok, _counts} = Plex.sync_library()

      assert Playback.facets_of_key!(Fill.genre_key()) == []
    end

    test "a second read of one genre writes one facet" do
      stub_library(one_section([artist(1)], [album(1, 1, ["Rap"]), album(2, 1, ["Rap"])], []))

      assert {:ok, _counts} = Plex.sync_library()
      assert {:ok, _counts} = Plex.sync_library()

      assert length(Playback.facets_of_key!(Fill.genre_key())) == 1
    end

    # **The record label arrives with the album on `studio`, so a read asks the server
    # for nothing more.** It becomes a facet in the way that a genre does, and the
    # Record labels branch is then a plain read of the facets.
    test "the record label of an album becomes a facet of it" do
      stub_library(one_section([artist(1)], [album(1, 1, [], "4AD")], []))

      assert {:ok, _counts} = Plex.sync_library()

      [facet] = Playback.facets_of_key!(Fill.record_label_key())

      assert to_string(facet.value.value) == "4AD"
    end

    test "the key of a record label names this source" do
      assert Fill.record_label_key() == "plex-record-label"
    end

    test "an album that names no record label writes no facet" do
      stub_library(one_section([artist(1)], [album(1, 1)], []))

      assert {:ok, _counts} = Plex.sync_library()

      assert Playback.facets_of_key!(Fill.record_label_key()) == []
    end

    test "a second read of one record label writes one facet" do
      stub_library(one_section([artist(1)], [album(1, 1, [], "4AD"), album(2, 1, [], "4AD")], []))

      assert {:ok, _counts} = Plex.sync_library()
      assert {:ok, _counts} = Plex.sync_library()

      assert length(Playback.facets_of_key!(Fill.record_label_key())) == 1
    end

    # **A genre and a record label of the same name are two rows, and they must be.**
    # The key of each facet names what it is, so the links of one cannot reach the
    # other.
    test "a genre and a record label of one name stay apart" do
      stub_library(one_section([artist(1)], [album(1, 1, ["4AD"], "4AD")], []))

      assert {:ok, _counts} = Plex.sync_library()

      [album] = Item |> Ash.Query.filter(source_ref == "album-1") |> Ash.read!(load: [:facets])

      assert album.facets |> Enum.map(& &1.key) |> Enum.sort() ==
               [Fill.genre_key(), Fill.record_label_key()]

      assert album.facets |> Enum.map(&to_string(&1.value.value)) |> Enum.uniq() == ["4AD"]
    end

    test "an album names its artist, and a track names its album" do
      stub_library(one_section([artist(1)], [album(1, 1)], [track(1, 1)]))

      assert {:ok, _counts} = Plex.sync_library()

      [artist] = Item |> Ash.Query.filter(source_ref == "artist-1") |> Ash.read!()
      [album] = Item |> Ash.Query.filter(source_ref == "album-1") |> Ash.read!()
      [track] = Item |> Ash.Query.filter(source_ref == "track-1") |> Ash.read!()

      assert artist.parent_id == nil
      assert album.parent_id == artist.id
      assert track.parent_id == album.id
    end

    # A person reads the life of an artist and the review of a record, and Plex gives
    # both in the listing under `summary`.
    test "an artist and an album carry what a person reads about them" do
      stub_library(one_section([artist(1)], [album(1, 1)], []))

      assert {:ok, _counts} = Plex.sync_library()

      [artist] = Item |> Ash.Query.filter(source_ref == "artist-1") |> Ash.read!()
      [album] = Item |> Ash.Query.filter(source_ref == "album-1") |> Ash.read!()

      assert artist.description == "The life of artist 1."
      assert album.description == "A review of album 1."
    end

    # A read that writes a row again must not empty what the first read wrote.
    test "a second read keeps the description" do
      stub_library(one_section([artist(1)], [], []))
      assert {:ok, _counts} = Plex.sync_library()
      assert {:ok, _counts} = Plex.sync_library()

      [artist] = Item |> Ash.Query.filter(source_ref == "artist-1") |> Ash.read!()
      assert artist.description == "The life of artist 1."
    end

    test "a track carries what a play and a mark need, and no address" do
      stub_library(one_section([artist(1)], [album(1, 1)], [track(1, 1)]))

      assert {:ok, _counts} = Plex.sync_library()

      [track] = items_of(:track)

      assert track.transport == :download
      assert track.format == :flac
      assert track.container_format == :none
      assert track.byte_size == 30_000_000
      assert track.source_key == "/library/parts/1/1/file.flac"
      assert track.url == nil
      refute track.keeps_place?
    end

    # **A track that this device cannot read as it is arrives as a conversion**, which is
    # a playlist and not a file. `caches_audio?` of `PiFi.Playback.Item` and
    # `PiFi.Player.skippable?/1` both name `transport == :download`, so the column is
    # what keeps a copy of an unreadable file off the card and the skip control dead.
    test "a track of a codec this firmware cannot read names hls as its transport" do
      alac = %{
        "ratingKey" => "track-alac",
        "title" => "In MP4",
        "parentRatingKey" => "album-1",
        "Media" => [
          %{
            "audioCodec" => "aac",
            "container" => "m4a",
            "Part" => [%{"key" => "/library/parts/9/1/file.m4a", "size" => 100}]
          }
        ]
      }

      stub_library(one_section([], [], [track(1, 1), alac]))

      assert {:ok, _counts} = Plex.sync_library()

      [plain] = Item |> Ash.Query.filter(source_ref == "track-1") |> Ash.read!()
      [converted] = Item |> Ash.Query.filter(source_ref == "track-alac") |> Ash.read!()

      assert plain.transport == :download
      assert plain.format == :flac
      assert converted.transport == :hls
      assert converted.format == :unknown
    end

    # **A Plex server holds a section for each library**, and a household with a
    # section of records and one of audiobooks must get both.
    test "it reads every music section of the server" do
      stub_library(%{
        "3" => %{artists() => [artist(1)], albums() => [album(1, 1)], tracks() => [track(1, 1)]},
        "5" => %{artists() => [artist(2)], albums() => [album(2, 2)], tracks() => [track(2, 2)]}
      })

      assert {:ok, counts} = Plex.sync_library()

      assert counts.artists == 2
      assert counts.albums == 2
      assert counts.tracks == 2
      assert length(all_items()) == 6
    end

    # An album of one section may name an artist of another, so every artist must be in
    # the catalogue before the first album arrives.
    test "every artist of every section comes before the first album" do
      stub_library(%{
        "3" => %{artists() => [artist(1)], albums() => [], tracks() => []},
        "5" => %{artists() => [], albums() => [album(1, 1)], tracks() => []}
      })

      assert {:ok, _counts} = Plex.sync_library()

      [album] = items_of(:container) |> Enum.filter(&(&1.source_ref == "album-1"))
      [artist] = items_of(:container) |> Enum.filter(&(&1.source_ref == "artist-1"))

      assert album.parent_id == artist.id
    end

    test "it reads a page at a time until it has the whole listing" do
      page_size = Server.page_size()
      many = Enum.map(1..(page_size + 3), &artist/1)
      stub_library(one_section(many, [], []))

      assert {:ok, counts} = Plex.sync_library()

      assert counts.artists == page_size + 3

      assert_receive {:request, :page, {"3", "8"}, 0}
      assert_receive {:request, :page, {"3", "8"}, ^page_size}
    end

    test "an album with no artist goes under one container that this source keeps" do
      stub_library(one_section([], [Map.delete(album(1, 1), "parentRatingKey")], []))

      assert {:ok, _counts} = Plex.sync_library()

      [unknown] =
        Item |> Ash.Query.filter(source_ref == ^Fill.unknown_artist_ref()) |> Ash.read!()

      [album] = Item |> Ash.Query.filter(source_ref == "album-1") |> Ash.read!()

      assert unknown.title == "Unknown artist"
      assert album.parent_id == unknown.id
    end

    # **The container of albums with no artist carries the stamp of the read.** A row
    # with no stamp would look like one that the server no longer has, and it would take
    # every album under it away.
    test "the container for albums with no artist survives the removal" do
      stub_library(one_section([], [Map.delete(album(1, 1), "parentRatingKey")], []))

      assert {:ok, %{removed: 0}} = Plex.sync_library()

      assert [_unknown, _album] = items_of(:container)
    end

    test "what the read did not see, it removes" do
      stub_library(one_section([artist(1), artist(2)], [], []))
      assert {:ok, _counts} = Plex.sync_library()
      assert length(all_items()) == 2

      stub_library(one_section([artist(1)], [], []))
      assert {:ok, %{removed: 1}} = Plex.sync_library()

      assert [%{source_ref: "artist-1"}] = all_items()
    end

    # A fault that names itself removes nothing. A read that stopped has seen no track,
    # and a remover that ran then would empty the catalogue.
    test "a read that fails leaves every row where it is" do
      stub_library(one_section([artist(1)], [], []))
      assert {:ok, _counts} = Plex.sync_library()

      Req.Test.stub(Server, fn conn ->
        Req.Test.json(Plug.Conn.put_status(conn, 401), %{})
      end)

      assert {:error, _reason} = Plex.sync_library()

      assert length(all_items()) == 1
    end

    # **A server with no music section is not a server whose music went.** A person who
    # pointed the device at the wrong server of their household must not lose the
    # library that they already read.
    test "a server with no music section removes nothing" do
      stub_library(one_section([artist(1)], [], []))
      assert {:ok, _counts} = Plex.sync_library()

      stub_library(%{})

      assert {:error, error} = Plex.sync_library()
      assert Exception.message(error) =~ "no_music_section"
      assert length(all_items()) == 1
    end

    test "a device that this source is out of use on asks the server nothing" do
      Source.enable(Source.Plex, false)
      on_exit(fn -> Source.enable(Source.Plex, true) end)

      Req.Test.stub(Server, fn _conn -> raise "the read reached the server" end)

      assert {:ok, %{skipped?: true, artists: 0}} = Plex.sync_library()
    end

    test "a device with no link asks the server nothing" do
      {:ok, token} = Settings.fetch(Server.token_setting())
      Settings.delete!(token)

      Req.Test.stub(Server, fn _conn -> raise "the read reached the server" end)

      assert {:ok, %{skipped?: true}} = Plex.sync_library()
    end

    # A page that shows a branch of this source reads it again, and a person is often
    # looking at the catalogue while the read writes it.
    test "it says that the library changed" do
      Event.subscribe(:source)
      stub_library(one_section([artist(1)], [], []))

      assert {:ok, _counts} = Plex.sync_library()

      assert_receive %Event.Source.Changed{source: Source.Plex, ref: :library}
    end

    test "a read that finished leaves no point behind" do
      stub_library(one_section([artist(1)], [], []))

      assert {:ok, _counts} = Plex.sync_library()

      assert Checkpoint.read() == :error
    end
  end

  describe "a read that stops continues where it stopped" do
    # **The time of the read carries over, and it must.** A read that continued with a
    # new time would call every row that the part already read wrote a row that the
    # server no longer has, and it would remove the lot.
    test "it continues from the kind, the section and the offset of the point" do
      stub_library(%{
        "3" => %{artists() => [artist(1)], albums() => [album(1, 1)], tracks() => []},
        "5" => %{artists() => [], albums() => [], tracks() => []}
      })

      Checkpoint.write(DateTime.utc_now(), :albums, "3", 0)

      assert {:ok, counts} = Plex.sync_library()

      assert counts.artists == 0
      assert counts.albums == 1
      refute_receive {:request, :page, {_section, "8"}, _start}
    end

    # The offset of an old point names a place in a list that the server may have
    # changed since, so continuing from it would step over items that this device never
    # read.
    test "a point of another day gives a fresh read" do
      stub_library(one_section([artist(1)], [], []))

      old = DateTime.add(DateTime.utc_now(), -7 * 60 * 60, :second)
      Checkpoint.write(old, :albums, "3", 0)

      assert {:ok, counts} = Plex.sync_library()

      assert counts.artists == 1
      assert_receive {:request, :page, {"3", "8"}, 0}
    end

    # A person who removed a library between two runs would otherwise send the read to a
    # section that answers 404, and every later kind would go unread.
    test "a point of a section that the server no longer lists gives a fresh read" do
      stub_library(one_section([artist(1)], [], []))

      Checkpoint.write(DateTime.utc_now(), :albums, "9999", 0)

      assert {:ok, counts} = Plex.sync_library()

      assert counts.artists == 1
      assert_receive {:request, :page, {"3", "8"}, 0}
    end
  end

  describe "cache_favourites" do
    test "a device that this source is out of use on asks for nothing" do
      Source.enable(Source.Plex, false)
      on_exit(fn -> Source.enable(Source.Plex, true) end)

      assert {:ok, 0} = Plex.cache_favourites()
    end

    test "a device with no link asks for nothing" do
      {:ok, token} = Settings.fetch(Server.token_setting())
      Settings.delete!(token)

      assert {:ok, 0} = Plex.cache_favourites()
    end

    test "a device with a link and no mark asks for nothing" do
      assert {:ok, 0} = Plex.cache_favourites()
    end
  end
end
