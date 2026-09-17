defmodule PiFi.Jellyfin.ServerTest do
  use PiFi.DataCase, async: false

  alias PiFi.Jellyfin.Server
  alias PiFi.Settings

  doctest Server, import: true

  @address "http://jellyfin.test"

  setup do
    Application.put_env(:pifi, Server, plug: {Req.Test, Server}, retry: false)
    on_exit(fn -> Application.delete_env(:pifi, Server) end)
    :ok
  end

  defp put_address, do: Settings.put!(Server.address_setting(), @address)

  defp put_link do
    put_address()
    Settings.put!(Server.token_setting(), "THETOKEN")
    Settings.put!(Server.user_setting(), "THEUSER")
    :ok
  end

  # Each stub sends the request back to the test, so a test can read the header, the
  # method and the query that the client built.
  defp stub(body, options \\ []) do
    status = Keyword.get(options, :status, 200)
    test = self()

    Req.Test.stub(Server, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test, {:request, conn.method, conn.request_path, conn.params, headers(conn)})

      Req.Test.json(Plug.Conn.put_status(conn, status), body)
    end)
  end

  # One answer for each method, so a test can read what a 405 on the POST does.
  defp stub_by_method(answers) do
    test = self()

    Req.Test.stub(Server, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test, {:request, conn.method, conn.request_path, conn.params, headers(conn)})

      {status, body} = Map.fetch!(answers, conn.method)

      Req.Test.json(Plug.Conn.put_status(conn, status), body)
    end)
  end

  defp headers(conn), do: Map.new(conn.req_headers)

  defp audio(overrides \\ %{}) do
    Map.merge(
      %{
        "Id" => "track-1",
        "Name" => "Teardrop",
        "Album" => "Mezzanine",
        "AlbumId" => "album-1",
        "AlbumArtist" => "Massive Attack",
        "Artists" => ["Massive Attack"],
        "Container" => "flac",
        "RunTimeTicks" => 3_296_000_000,
        "MediaSources" => [%{"Size" => 41_000_000}],
        "ImageTags" => %{"Primary" => "abc"}
      },
      overrides
    )
  end

  describe "the header of a request" do
    test "it names the client, the device and the token" do
      put_link()
      stub(%{"Items" => [], "TotalRecordCount" => 0})

      assert {:ok, _page} = Server.page(:tracks, 0)

      assert_receive {:request, "GET", "/Items", _params, headers}

      assert headers["authorization"] =~ ~s(MediaBrowser Client="PiFi")
      assert headers["authorization"] =~ ~s(Token="THETOKEN")
      assert headers["authorization"] =~ ~s(DeviceId="#{Server.device_id()}")
    end

    # **`DateCreated` is absent unless a caller asks for it.** A read of a real server
    # on 2026-09-09 gave `PremiereDate` and `ProductionYear` with no `Fields` at all,
    # and `DateCreated` only with `Fields=DateCreated`. `Recently added` reads that
    # date, so a page of albums that stopped asking would sort every album alike.
    test "a page of albums asks the server for the date that it holds" do
      put_link()
      stub(%{"Items" => [], "TotalRecordCount" => 0})

      assert {:ok, _page} = Server.page(:albums, 0)

      assert_receive {:request, "GET", "/Items", params, _headers}
      assert params["Fields"] == "DateCreated,Genres"
    end

    # A page of tracks is the largest page that this source reads, and it needs the
    # size of each file. The date of an album is not on it.
    test "a page of tracks asks for the size of a file and no date" do
      put_link()
      stub(%{"Items" => [], "TotalRecordCount" => 0})

      assert {:ok, _page} = Server.page(:tracks, 0)

      assert_receive {:request, "GET", "/Items", params, _headers}
      assert params["Fields"] == "MediaSources"
    end

    # The server lists one device for each identifier that it meets, so an identifier
    # that changed at each boot would fill that list.
    test "the identifier of the device stays the same" do
      first = Server.device_id()

      assert Server.device_id() == first
      assert {:ok, %{value: ^first}} = Settings.fetch(Server.device_id_setting())
    end
  end

  describe "public_info/1" do
    test "it names the server, so a person knows that they typed the right address" do
      stub(%{"ServerName" => "The Cupboard", "Version" => "10.10.3"})

      assert {:ok, info} = Server.public_info(@address)
      assert info.name == "The Cupboard"
      assert info.version == "10.10.3"

      assert_receive {:request, "GET", "/System/Info/Public", _params, _headers}
    end

    test "an answer that is no Jellyfin server gives the status" do
      stub(%{"nonsense" => true}, status: 404)

      assert {:error, :not_found} = Server.public_info(@address)
    end

    test "a network fault gives the reason of `Req`" do
      Req.Test.stub(Server, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} = Server.public_info(@address)
    end
  end

  describe "quick_connect/0" do
    test "it gives the code that a person types, and the secret that names the try" do
      put_address()
      stub(%{"Secret" => "s3cr3t", "Code" => "123456"})

      assert {:ok, %{secret: "s3cr3t", code: "123456"}} = Server.quick_connect()

      assert_receive {:request, "POST", "/QuickConnect/Initiate", _params, _headers}
    end

    # An administrator can turn Quick Connect off, and the server then answers 401. A
    # person must read that as a choice of their server and not as a fault.
    test "a 401 says that the server turned Quick Connect off" do
      put_address()
      stub(%{"nonsense" => true}, status: 401)

      assert {:error, :quick_connect_off} = Server.quick_connect()
    end

    # A server of an older version takes a GET here and answers 405 for the POST.
    test "a 405 on the POST sends the same request as a GET" do
      put_address()

      stub_by_method(%{
        "POST" => {405, %{"nonsense" => true}},
        "GET" => {200, %{"Secret" => "s3cr3t", "Code" => "ABC123"}}
      })

      assert {:ok, %{code: "ABC123"}} = Server.quick_connect()

      assert_receive {:request, "POST", "/QuickConnect/Initiate", _params, _headers}
      assert_receive {:request, "GET", "/QuickConnect/Initiate", _params, _headers}
    end

    test "a device with no address asks nothing" do
      Req.Test.stub(Server, fn _conn -> raise "the server must not be asked" end)

      assert {:error, :no_address} = Server.quick_connect()
    end

    test "an answer with no code gives an error" do
      put_address()
      stub(%{"Secret" => "s3cr3t"})

      assert {:error, :no_code} = Server.quick_connect()
    end
  end

  describe "quick_connect_state/1" do
    test "it waits until a person types the code" do
      put_address()
      stub(%{"Authenticated" => false})

      assert {:ok, :waiting} = Server.quick_connect_state("s3cr3t")

      assert_receive {:request, "GET", "/QuickConnect/Connect", params, _headers}
      assert params["secret"] == "s3cr3t"
    end

    test "it says when a person has typed it" do
      put_address()
      stub(%{"Authenticated" => true})

      assert {:ok, :authenticated} = Server.quick_connect_state("s3cr3t")
    end

    # A code lives for a few minutes, and the server then holds the secret no more.
    test "a 404 says that the server holds that secret no more" do
      put_address()
      stub(%{"nonsense" => true}, status: 404)

      assert {:error, :unknown_secret} = Server.quick_connect_state("s3cr3t")
    end
  end

  describe "authenticate_with_quick_connect/1" do
    test "it keeps the token and the user" do
      put_address()
      Settings.put!(Server.secret_setting(), "s3cr3t")
      Settings.put!(Server.code_setting(), "123456")

      stub(%{"AccessToken" => "THETOKEN", "User" => %{"Id" => "THEUSER"}})

      assert {:ok, "THETOKEN"} = Server.authenticate_with_quick_connect("s3cr3t")

      assert_receive {:request, "POST", "/Users/AuthenticateWithQuickConnect", _params, _headers}

      assert {:ok, %{value: "THETOKEN"}} = Settings.fetch(Server.token_setting())
      assert {:ok, %{value: "THEUSER"}} = Settings.fetch(Server.user_setting())
      assert Server.configured?()
    end

    # Nothing waits for a link that is done, so the page shows no stale code.
    test "the secret and the code go when the link is done" do
      put_address()
      Settings.put!(Server.secret_setting(), "s3cr3t")
      Settings.put!(Server.code_setting(), "123456")

      stub(%{"AccessToken" => "THETOKEN", "User" => %{"Id" => "THEUSER"}})

      assert {:ok, _token} = Server.authenticate_with_quick_connect("s3cr3t")

      assert {:error, _reason} = Settings.fetch(Server.secret_setting())
      assert {:error, _reason} = Settings.fetch(Server.code_setting())
    end

    test "an answer with no token gives an error and keeps no link" do
      put_address()
      stub(%{"AccessToken" => "THETOKEN"})

      assert {:error, :no_token} = Server.authenticate_with_quick_connect("s3cr3t")
      refute Server.configured?()
    end
  end

  describe "authenticate_by_name/2" do
    test "it keeps the token and the user" do
      put_address()
      stub(%{"AccessToken" => "THETOKEN", "User" => %{"Id" => "THEUSER"}})

      assert {:ok, "THETOKEN"} = Server.authenticate_by_name("james", "hunter2")

      assert_receive {:request, "POST", "/Users/AuthenticateByName", _params, _headers}
      assert Server.configured?()
    end

    test "a 401 says that the server refused the name" do
      put_address()
      stub(%{"nonsense" => true}, status: 401)

      assert {:error, :unauthorised} = Server.authenticate_by_name("james", "wrong")
      refute Server.configured?()
    end
  end

  describe "forget/0" do
    test "the token goes, and the address and the device stay" do
      put_link()
      first = Server.device_id()

      assert :ok = Server.forget()

      refute Server.configured?()
      assert {:ok, @address} = Server.address()
      assert Server.device_id() == first
    end
  end

  describe "configured?/0" do
    test "a link needs the address, the token and the user" do
      refute Server.configured?()

      put_address()
      refute Server.configured?()

      Settings.put!(Server.token_setting(), "THETOKEN")
      refute Server.configured?()

      Settings.put!(Server.user_setting(), "THEUSER")
      assert Server.configured?()
    end
  end

  describe "page/2" do
    test "it asks for the artists of the whole library, in the order of the name" do
      put_link()
      stub(%{"Items" => [], "TotalRecordCount" => 0})

      assert {:ok, _page} = Server.page(:artists, 0)

      assert_receive {:request, "GET", "/Items", params, _headers}
      assert params["IncludeItemTypes"] == "MusicArtist"
      assert params["Recursive"] == "true"
      assert params["SortBy"] == "SortName"
      assert params["UserId"] == "THEUSER"
      assert params["StartIndex"] == "0"
      assert params["Limit"] == to_string(Server.page_size())
    end

    test "it names each kind of item" do
      put_link()
      stub(%{"Items" => [], "TotalRecordCount" => 0})

      Server.page(:albums, 0)
      assert_receive {:request, _method, _path, %{"IncludeItemTypes" => "MusicAlbum"}, _headers}

      Server.page(:tracks, 40)
      assert_receive {:request, _method, _path, %{"IncludeItemTypes" => "Audio"} = params, _h}
      assert params["StartIndex"] == "40"
    end

    # The size of a file is the one thing that only `MediaSources` names, and
    # `PiFi.Playback.FavouriteAudio` reads it before it asks for a track.
    test "the tracks alone ask for the media sources" do
      put_link()
      stub(%{"Items" => [], "TotalRecordCount" => 0})

      Server.page(:tracks, 0)
      assert_receive {:request, _method, _path, %{"Fields" => "MediaSources"}, _headers}

      Server.page(:artists, 0)
      assert_receive {:request, _method, _path, params, _headers}
      refute Map.has_key?(params, "Fields")
    end

    test "it counts what the answer held and what the listing holds" do
      put_link()

      stub(%{
        "Items" => [audio(), audio(%{"Id" => nil}), %{"nonsense" => true}],
        "TotalRecordCount" => 900
      })

      assert {:ok, page} = Server.page(:tracks, 0)

      # Two of the three cannot become a row, and the count still moves by three, or
      # a sync would read the same page for ever.
      assert length(page.entries) == 1
      assert page.count == 3
      assert page.total == 900
    end

    test "a device with no link asks nothing" do
      Req.Test.stub(Server, fn _conn -> raise "the server must not be asked" end)

      assert {:error, :no_address} = Server.page(:tracks, 0)

      put_address()

      assert {:error, :not_linked} = Server.page(:tracks, 0)
    end
  end

  describe "artist/2" do
    test "an artist holds no parent, so it is the top of the tree" do
      item = %{"Id" => "artist-1", "Name" => "Massive Attack", "ImageTags" => %{"Primary" => "a"}}

      assert Server.artist(item, @address) == %{
               ref: "artist-1",
               title: "Massive Attack",
               parent_ref: nil,
               artwork_url: "#{@address}/Items/artist-1/Images/Primary?maxHeight=600"
             }
    end

    test "an item with no picture of its own holds no address" do
      assert %{artwork_url: nil} =
               Server.artist(%{"Id" => "artist-1", "Name" => "Massive Attack"}, @address)
    end

    test "an item with no identifier or no name becomes nothing" do
      assert Server.artist(%{"Name" => "Massive Attack"}, @address) == nil
      assert Server.artist(%{"Id" => "artist-1"}, @address) == nil
      assert Server.artist(%{"Id" => "artist-1", "Name" => "  "}, @address) == nil
      assert Server.artist(%{}, @address) == nil
      assert Server.artist(nil, @address) == nil
    end
  end

  describe "album/2" do
    test "an album names its artist" do
      item = %{
        "Id" => "album-1",
        "Name" => "Mezzanine",
        "AlbumArtist" => "Massive Attack",
        "AlbumArtists" => [%{"Id" => "artist-1", "Name" => "Massive Attack"}],
        "PremiereDate" => "1998-04-20T00:00:00.0000000Z",
        "ProductionYear" => 1998
      }

      assert entry = Server.album(item, @address)
      assert entry.parent_ref == "artist-1"
      assert entry.subtitle == "Massive Attack"
      assert entry.published_at == ~U[1998-04-20 00:00:00.000000Z]
      assert entry.release_year == 1998
    end

    test "an album needs no premiere date to hold its release year" do
      assert %{published_at: nil, release_year: 1998} =
               Server.album(
                 %{"Id" => "a", "Name" => "Mezzanine", "ProductionYear" => 1998},
                 @address
               )
    end

    # `DateCreated` is when the server first held the album, and `PremiereDate` is the
    # release. A record of 1998 that a person added this year gives the two 28 years
    # apart, and `Recently added` needs the second one.
    test "an album holds the date that the server first held it" do
      item = %{
        "Id" => "album-1",
        "Name" => "Mezzanine",
        "PremiereDate" => "1998-04-20T00:00:00.0000000Z",
        "DateCreated" => "2026-09-02T23:06:22.0140647Z"
      }

      assert entry = Server.album(item, @address)
      assert entry.added_at == ~U[2026-09-02 23:06:22.014064Z]
      assert entry.published_at == ~U[1998-04-20 00:00:00.000000Z]
    end

    # A server of an older version names no such date, and a library still reads.
    test "an album that names no date holds none" do
      assert %{added_at: nil} = Server.album(%{"Id" => "a", "Name" => "Mezzanine"}, @address)
    end

    test "an album whose artist the server does not name holds no parent" do
      assert %{parent_ref: nil} = Server.album(%{"Id" => "a", "Name" => "Mezzanine"}, @address)
    end
  end

  describe "track/2" do
    test "a track names its artist, its album, its length and its size" do
      assert entry = Server.track(audio(), @address)

      assert entry.parent_ref == "album-1"
      assert entry.subtitle == "Massive Attack"
      assert entry.duration_ms == 329_600
      assert entry.byte_size == 41_000_000
      assert entry.format == :flac
    end

    # The pipeline decodes these three as they are, and the address of the audio names
    # the same container back.
    test "the container of the server decides the codec" do
      assert %{format: :flac} = Server.track(audio(%{"Container" => "flac"}), @address)
      assert %{format: :mp3} = Server.track(audio(%{"Container" => "mp3"}), @address)
      assert %{format: :aac} = Server.track(audio(%{"Container" => "aac"}), @address)
    end

    # ALAC, WAV, AIFF, WMA and Opus are each rare in a music library, and the server
    # converts every one of them.
    test "a container that this firmware does not decode becomes MP3" do
      assert %{format: :mp3} = Server.track(audio(%{"Container" => "alac"}), @address)
      assert %{format: :mp3} = Server.track(audio(%{"Container" => nil}), @address)
    end

    test "a track with no media source holds no size, and the guard estimates one" do
      assert %{byte_size: nil} = Server.track(audio(%{"MediaSources" => nil}), @address)
      assert %{byte_size: nil} = Server.track(audio(%{"MediaSources" => []}), @address)

      assert %{byte_size: nil} =
               Server.track(audio(%{"MediaSources" => [%{"Size" => 0}]}), @address)
    end

    # A person who opens a compilation reads the artist of each track, and the artist of
    # the record says the same thing for every row of that list.
    test "the artist of the track takes the place of the artist of the record" do
      assert %{subtitle: "Elizabeth Fraser"} =
               Server.track(audio(%{"Artists" => ["Elizabeth Fraser"]}), @address)
    end

    test "a track of more than one artist names them all" do
      assert %{subtitle: "Tricky, Martina Topley-Bird"} =
               Server.track(
                 audio(%{"Artists" => ["Tricky", " ", "Martina Topley-Bird"]}),
                 @address
               )
    end

    test "the artist of the record names the line under a track that names none" do
      assert %{subtitle: "Massive Attack"} = Server.track(audio(%{"Artists" => nil}), @address)
      assert %{subtitle: "Massive Attack"} = Server.track(audio(%{"Artists" => []}), @address)
    end

    test "a track that names no artist at all holds no line under its title" do
      assert %{subtitle: nil} =
               Server.track(audio(%{"Artists" => [], "AlbumArtist" => nil}), @address)
    end
  end

  describe "stream_url/2" do
    test "it names the container that the pipeline expects, and the token" do
      put_link()

      assert {:ok, uri} = Server.stream_url("track-1", :flac)

      assert uri =~ "#{@address}/Audio/track-1/universal?"

      query = uri |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert query["container"] == "flac"
      assert query["UserId"] == "THEUSER"
      assert query["api_key"] == "THETOKEN"
      assert query["DeviceId"] == Server.device_id()
      # A limit that no music file of a normal library passes, so a track converts
      # for its container and never for its bitrate.
      assert query["maxStreamingBitrate"] == "8000000"
    end

    # `audioCodec` names what a conversion gives, and FLAC and AAC reach this device
    # as they are.
    test "a track that the server converts names the codec that it must give" do
      put_link()

      assert {:ok, uri} = Server.stream_url("track-1", :mp3)
      query = uri |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert query["container"] == "mp3"
      assert query["audioCodec"] == "mp3"

      assert {:ok, flac} = Server.stream_url("track-1", :flac)
      flac_query = flac |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      refute Map.has_key?(flac_query, "audioCodec")
    end

    test "a device with no link gives no address" do
      assert {:error, :no_address} = Server.stream_url("track-1", :flac)

      put_address()

      assert {:error, :not_linked} = Server.stream_url("track-1", :flac)
    end
  end
end
