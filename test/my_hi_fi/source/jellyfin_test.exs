defmodule MyHiFi.Source.JellyfinTest do
  use MyHiFi.DataCase, async: false
  use Oban.Testing, repo: MyHiFi.Repo

  require Ash.Query

  alias MyHiFi.Jellyfin.Fill
  alias MyHiFi.Jellyfin.Server
  alias MyHiFi.Playback
  alias MyHiFi.Settings
  alias MyHiFi.Source
  alias MyHiFi.Source.Jellyfin

  @address "http://jellyfin.test"

  setup do
    Application.put_env(:my_hi_fi, Server, plug: {Req.Test, Server}, retry: false)
    on_exit(fn -> Application.delete_env(:my_hi_fi, Server) end)
    :ok
  end

  defp put_address, do: Settings.put!(Server.address_setting(), @address)

  defp put_link do
    put_address()
    Settings.put!(Server.token_setting(), "THETOKEN")
    Settings.put!(Server.user_setting(), "THEUSER")
    :ok
  end

  defp stub(body, options \\ []) do
    status = Keyword.get(options, :status, 200)

    Req.Test.stub(Server, fn conn ->
      Req.Test.json(Plug.Conn.put_status(conn, status), body)
    end)
  end

  defp album do
    Fill.albums([
      %{ref: "album-1", title: "Mezzanine", parent_ref: nil, artwork_url: nil, subtitle: nil}
    ])

    one_of("album-1")
  end

  defp track(overrides \\ %{}) do
    attributes =
      Map.merge(
        %{
          ref: "track-1",
          title: "Teardrop",
          parent_ref: "album-1",
          artwork_url: nil,
          subtitle: "Massive Attack",
          duration_ms: 329_600,
          byte_size: 41_000_000,
          format: :flac
        },
        overrides
      )

    Fill.tracks([attributes])

    one_of(attributes.ref)
  end

  describe "the order of the tracks of an album" do
    # **A sort of two columns cannot hold this**, because `Cinder.QueryBuilder` unsets
    # the sort of a query when a person presses a sort control and applies the one
    # column that they pressed. A set of two discs read 1-01, 2-01, 1-02, 2-02 on a
    # device. See the `place` calculation of `MyHiFi.Playback.Item`.
    test "a set of two discs reads one disc after the other" do
      album()

      for {ref, disc, number} <- [
            {"a-2-01", 2, 1},
            {"a-1-02", 1, 2},
            {"a-2-02", 2, 2},
            {"a-1-01", 1, 1}
          ] do
        track(%{ref: ref, title: ref, number: number, disc: disc})
      end

      assert ~w(a-1-01 a-1-02 a-2-01 a-2-02) == titles_in_order()

      # **This is the assertion that the device needed.** The sort above holds two
      # columns, and Cinder throws away every column but the one that a person pressed,
      # so the order must be right with that one alone.
      assert ~w(a-1-01 a-1-02 a-2-01 a-2-02) == titles_by_control()
    end

    # An album of one disc names none, so the number alone decides.
    test "an album of one disc reads by its track number" do
      album()
      track(%{ref: "one", title: "one", number: 1})
      track(%{ref: "two", title: "two", number: 2})
      track(%{ref: "ten", title: "ten", number: 10})

      assert ~w(one two ten) == titles_in_order()
    end

    # A server that names no number leaves the place absent, and SQLite reads that as
    # the smallest value, so such a track leads and the title decides between them.
    test "a track with no number leads, and the title then decides" do
      album()
      track(%{ref: "numbered", title: "The numbered one", number: 2})
      track(%{ref: "bare", title: "A bare one"})

      assert ["A bare one", "The numbered one"] == titles_in_order()
    end
  end

  # The read that a page makes: the items of the album, in the order that the source
  # names for the items inside it.
  defp titles_in_order, do: titles(Source.inside(Jellyfin, album()).sort)

  # The read that a page makes after a person presses the sort control.
  # `Cinder.QueryBuilder.apply_sorting/2` unsets the sort of the query and applies the
  # one column that the control names, so this is the order that a device shows.
  defp titles_by_control do
    {_label, field} = Source.inside(Jellyfin, album()).order

    titles([{String.to_existing_atom(field), :asc}])
  end

  defp titles(sort) do
    MyHiFi.Playback.Item
    |> Ash.Query.filter(parent_id == ^album().id)
    |> Ash.Query.sort(sort)
    |> Ash.read!()
    |> Enum.map(& &1.title)
  end

  defp one_of(ref) do
    Playback.list_items!()
    |> Enum.find(&(&1.source == Fill.source() and &1.source_ref == ref))
  end

  describe "what the source says about itself" do
    test "it names itself and its icon" do
      assert Jellyfin.title() == "Jellyfin"
      # The mark of the service, and not the shelf that `:library` draws.
      assert Jellyfin.icon() == :jellyfin
      assert Jellyfin.kinds() == [container: "Albums", track: "Tracks"]
    end

    test "its name in an address comes from the module, and the fill writes the same one" do
      assert Source.slug(Jellyfin) == "jellyfin"
      assert Fill.source() == "jellyfin"
      assert {:ok, Jellyfin} = Source.from_slug("jellyfin")
    end

    test "the firmware holds it" do
      assert Jellyfin in Source.all()
    end

    # A song lasts three minutes, and this source gives FLAC, which
    # `MyHiFi.Player.Skip` cannot move inside.
    test "it holds no skip and no search" do
      assert Jellyfin.capabilities() == []
    end

    test "a device with no link is not ready, so no job asks the server" do
      refute Jellyfin.ready?()

      put_link()

      assert Jellyfin.ready?()
    end
  end

  describe "roots/0" do
    test "the four branches read the catalogue and reach no server" do
      Req.Test.stub(Server, fn _conn -> raise "the server must not be asked" end)

      Fill.artists([
        %{ref: "artist-1", title: "Massive Attack", parent_ref: nil, artwork_url: nil}
      ])

      Fill.albums([
        %{
          ref: "album-1",
          title: "Mezzanine",
          parent_ref: "artist-1",
          artwork_url: nil,
          subtitle: "Massive Attack"
        }
      ])

      one = track()
      {:ok, _item} = Playback.set_favourite(one)

      assert [
               {"Artists", artists},
               {"Albums", albums},
               {"Recently added", recent},
               {"Favourites", favourites}
             ] = Jellyfin.roots()

      assert Enum.map(Ash.read!(artists.query), & &1.title) == ["Massive Attack"]
      assert Enum.map(Ash.read!(albums.query), & &1.title) == ["Mezzanine"]
      assert Enum.map(Ash.read!(recent.query), & &1.title) == ["Mezzanine"]
      assert Enum.map(Ash.read!(favourites.query), & &1.title) == ["Teardrop"]

      assert [artists.kind, albums.kind, recent.kind, favourites.kind] ==
               [:item, :item, :item, :item]

      assert albums.facts == [:subtitle, :release_year]
      assert recent.facts == [:subtitle, :release_year]
      assert favourites.facts == [:subtitle, :release_year]
      # An artist is the one container of this source with no parent, so the Artists
      # branch needs no facet and no column of its own.
      assert one_of("artist-1").parent_id == nil
    end

    test "the albums of an artist show a release year, and the tracks of an album do not" do
      artist = struct(MyHiFi.Playback.Item, kind: :container, parent_id: nil)
      album = struct(MyHiFi.Playback.Item, kind: :container, parent_id: "artist-1")

      assert Source.inside(Jellyfin, artist).facts == [:subtitle, :release_year]
      assert Source.inside(Jellyfin, album).facts == [:subtitle, :duration_ms]
    end

    test "no branch shows an item of another source" do
      MyHiFi.Playback.upsert_item!(%{
        source: "podcasts",
        source_ref: "a-show",
        kind: :container,
        title: "A show"
      })

      assert [{"Artists", artists} | _rest] = Jellyfin.roots()

      assert Ash.read!(artists.query) == []
    end
  end

  describe "the recently added branch" do
    setup do
      Req.Test.stub(Server, fn _conn -> raise "the server must not be asked" end)

      Fill.artists([%{ref: "artist-1", title: "An artist", parent_ref: nil, artwork_url: nil}])

      :ok
    end

    # The newest record of the library is the first row, and a limit of 20 is absent:
    # the first page holds the last handful and the list holds the rest.
    test "the album that the server held last comes first" do
      album("old", ~U[2024-01-01 00:00:00.000000Z])
      album("new", ~U[2026-09-01 00:00:00.000000Z])
      album("middle", ~U[2025-06-01 00:00:00.000000Z])

      assert titles() == ["new", "middle", "old"]
    end

    # A server of an older version names no such date, and a row of a firmware before
    # this column holds none either. A person who asked for the newest expects those
    # after every album that names a date.
    test "an album that holds no date comes last" do
      album("nameless", nil)
      album("dated", ~U[2024-01-01 00:00:00.000000Z])

      assert titles() == ["dated", "nameless"]
    end

    # **The date of the release is not the date that the album arrived.** A person who
    # buys a record of 1979 this week must read it at the top.
    test "it reads the date of the service and not the release" do
      album("old record, new to me", ~U[2026-09-01 00:00:00.000000Z], 1979)
      album("new record, here a while", ~U[2024-01-01 00:00:00.000000Z], 2024)

      assert titles() == ["old record, new to me", "new record, here a while"]
    end

    test "an artist is absent, because a person asked for albums" do
      album("an album", ~U[2026-09-01 00:00:00.000000Z])

      assert titles() == ["an album"]
    end

    defp album(title, added_at, release_year \\ nil) do
      Fill.albums([
        %{
          ref: "album-#{title}",
          title: title,
          parent_ref: "artist-1",
          artwork_url: nil,
          added_at: added_at,
          release_year: release_year
        }
      ])
    end

    defp titles do
      [_artists, _albums, {"Recently added", recent} | _rest] = Jellyfin.roots()

      Enum.map(Ash.read!(recent.query), & &1.title)
    end
  end

  describe "resolve/1" do
    test "a FLAC track plays as it is, from a file that a download writes" do
      put_link()
      one = track()

      assert {:ok, playable} = Jellyfin.resolve(one)

      assert playable.transport == :download
      assert playable.container == :none
      assert playable.format == :flac
      assert playable.live? == false
      assert playable.key == one.id
      assert playable.headers == []
      # A song keeps no place, so it plays from the start every time.
      assert playable.position_ms == 0
      assert playable.position_bytes == 0

      query = playable.uri |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert playable.uri =~ "#{@address}/Audio/track-1/universal"
      assert query["container"] == "flac"
      refute Map.has_key?(query, "audioCodec")
    end

    # ALAC, WAV and the rest are rare, and the fill wrote `:mp3` for each one, so the
    # address names the container that the server must give.
    test "a track that the server converts asks for MP3" do
      put_link()
      one = track(%{ref: "track-2", format: :mp3})

      assert {:ok, playable} = Jellyfin.resolve(one)

      query = playable.uri |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert playable.format == :mp3
      assert query["container"] == "mp3"
      assert query["audioCodec"] == "mp3"
    end

    test "a container plays nothing" do
      put_link()

      assert {:error, {:not_a_track, _id}} = Jellyfin.resolve(album())
    end

    test "a device with no link names the reason" do
      one = track()

      assert {:error, :no_address} = Jellyfin.resolve(one)
    end

    test "a track that no read has filled names the reason, and it does not raise" do
      put_link()
      one = track()

      assert {:error, {:not_read_yet, "Teardrop"}} = Jellyfin.resolve(%{one | format: nil})
    end
  end

  describe "put_settings/1" do
    test "it asks the address whether a Jellyfin server answers there" do
      stub(%{"ServerName" => "The Cupboard"})

      assert {:ok, message} = Jellyfin.put_settings(%{"address" => @address})

      assert message =~ "The Cupboard"
      assert {:ok, @address} = Server.address()
    end

    test "an address with no scheme takes one, and a separator at the end goes" do
      stub(%{"ServerName" => "The Cupboard"})

      assert {:ok, _message} = Jellyfin.put_settings(%{"address" => " jellyfin.test:8096/ "})

      assert {:ok, "http://jellyfin.test:8096"} = Server.address()
    end

    test "an address that answers nothing is not stored" do
      Req.Test.stub(Server, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, message} = Jellyfin.put_settings(%{"address" => @address})

      assert message =~ "No Jellyfin server answered"
      assert {:error, :no_address} = Server.address()
    end

    test "an empty address names what a person must give" do
      assert {:error, message} = Jellyfin.put_settings(%{"address" => "   "})
      assert message =~ "Give the address of your server"

      assert {:error, _message} = Jellyfin.put_settings(%{})
    end

    test "a name and a password link the device, for a server with no Quick Connect" do
      Req.Test.stub(Server, fn conn ->
        case conn.request_path do
          "/System/Info/Public" -> Req.Test.json(conn, %{"ServerName" => "The Cupboard"})
          _other -> Req.Test.json(conn, %{"AccessToken" => "T", "User" => %{"Id" => "U"}})
        end
      end)

      assert {:ok, message} =
               Jellyfin.put_settings(%{
                 "address" => @address,
                 "username" => "james",
                 "password" => "hunter2"
               })

      assert message =~ "accepted that name"
      assert Server.configured?()
    end

    test "an address with no name and no password stores the address alone" do
      stub(%{"ServerName" => "The Cupboard"})

      assert {:ok, _message} =
               Jellyfin.put_settings(%{"address" => @address, "username" => "", "password" => ""})

      assert {:ok, @address} = Server.address()
      refute Server.configured?()
    end
  end

  describe "settings/0" do
    test "the description of the address says what state the link is in" do
      assert [address | _rest] = Jellyfin.settings()
      assert address.description =~ "Give the address of your server"
      assert address.value == nil

      put_address()
      assert [address | _rest] = Jellyfin.settings()
      assert address.description =~ "is not linked yet"
      assert address.value == @address

      put_link()
      track()
      assert [address | _rest] = Jellyfin.settings()
      assert address.description =~ "This device is linked to a server. The library has 1 track."
    end

    # The doc of the callback says that a source reads its own state here, and a
    # description may hold a state that changes. This source holds no callback of its
    # own for the wait.
    test "the wait for a code shows in the description of the address" do
      put_address()
      Settings.put!(Server.secret_setting(), "s3cr3t")
      Settings.put!(Server.code_setting(), "ABC123")

      assert [address | _rest] = Jellyfin.settings()

      assert address.description =~ "ABC123"
      assert address.description =~ "Quick Connect"
    end

    test "the device never sends a name or a password back to a browser" do
      assert [_address, username, password] = Jellyfin.settings()

      assert username.write_only? == true
      assert username.value == nil
      assert password.type == :password
      assert password.write_only? == true
      assert password.value == nil
    end
  end

  describe "the link flow" do
    test "the control asks for a code, and the answer holds it" do
      put_address()
      stub(%{"Secret" => "s3cr3t", "Code" => "ABC123"})

      assert {:ok, message} = Jellyfin.run_settings_action("link")

      assert message =~ "ABC123"
      assert {:ok, %{value: "s3cr3t"}} = Settings.fetch(Server.secret_setting())
    end

    test "a server that turned Quick Connect off names the other way" do
      put_address()
      stub(%{"nonsense" => true}, status: 401)

      assert {:error, message} = Jellyfin.run_settings_action("link")

      assert message =~ "Quick Connect off"
      assert message =~ "user name and a password"
    end

    test "the second control takes the token once a person has typed the code" do
      put_address()
      Settings.put!(Server.secret_setting(), "s3cr3t")
      Settings.put!(Server.code_setting(), "ABC123")

      Req.Test.stub(Server, fn conn ->
        case conn.request_path do
          "/QuickConnect/Connect" -> Req.Test.json(conn, %{"Authenticated" => true})
          _other -> Req.Test.json(conn, %{"AccessToken" => "T", "User" => %{"Id" => "U"}})
        end
      end)

      assert {:ok, message} = Jellyfin.run_settings_action("finish_link")

      assert message =~ "The device is linked"
      assert Server.configured?()
    end

    test "a person who has not typed the code yet reads the code again" do
      put_address()
      Settings.put!(Server.secret_setting(), "s3cr3t")
      Settings.put!(Server.code_setting(), "ABC123")
      stub(%{"Authenticated" => false})

      assert {:ok, message} = Jellyfin.run_settings_action("finish_link")

      assert message =~ "ABC123"
      refute Server.configured?()
    end

    test "a code that ran out of time goes, so no stale code stays on the page" do
      put_address()
      Settings.put!(Server.secret_setting(), "s3cr3t")
      Settings.put!(Server.code_setting(), "ABC123")
      stub(%{"nonsense" => true}, status: 404)

      assert {:error, message} = Jellyfin.run_settings_action("finish_link")

      assert message =~ "ran out of time"
      assert {:error, _reason} = Settings.fetch(Server.code_setting())
    end

    test "the controls follow the state of the link" do
      put_address()
      assert Enum.map(Jellyfin.settings_actions(), & &1.name) == ["link"]

      Settings.put!(Server.secret_setting(), "s3cr3t")
      Settings.put!(Server.code_setting(), "ABC123")
      assert Enum.map(Jellyfin.settings_actions(), & &1.name) == ["finish_link", "link"]

      put_link()
      assert Enum.map(Jellyfin.settings_actions(), & &1.name) == ["read_library", "remove_link"]
    end

    test "removing the link forgets the token and keeps the address" do
      put_link()

      assert {:ok, message} = Jellyfin.run_settings_action("remove_link")

      assert message =~ "holds no link"
      refute Server.configured?()
      assert {:ok, @address} = Server.address()
    end

    test "a read of the library goes to a job, so a person waits for no network" do
      put_link()

      assert {:ok, _message} = Jellyfin.run_settings_action("read_library")

      assert_enqueued(worker: MyHiFi.Jellyfin.Sync.Workers.Library)
    end

    test "a control that this source does not hold gives an error" do
      assert {:error, _message} = Jellyfin.run_settings_action("nonsense")
    end
  end
end
