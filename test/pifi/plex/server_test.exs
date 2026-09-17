defmodule PiFi.Plex.ServerTest do
  use PiFi.DataCase, async: false

  alias PiFi.Plex.Server
  alias PiFi.Settings

  doctest Server, import: true

  @address "http://plex.test:32400"

  setup do
    Application.put_env(:pifi, Server, plug: {Req.Test, Server}, retry: false)
    on_exit(fn -> Application.delete_env(:pifi, Server) end)
    :ok
  end

  defp put_link do
    Settings.put!(Server.address_setting(), @address)
    Settings.put!(Server.token_setting(), "THETOKEN")
    :ok
  end

  defp put_account, do: Settings.put!(Server.account_setting(), "THEACCOUNT")

  # Each stub sends the request back to the test, so a test can read the headers, the
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

  defp headers(conn), do: Map.new(conn.req_headers)

  defp container(metadata, extra \\ %{}) do
    %{"MediaContainer" => Map.merge(%{"Metadata" => metadata}, extra)}
  end

  defp media(codec, container) do
    %{
      "audioCodec" => codec,
      "container" => container,
      "Part" => [%{"key" => "/library/parts/44/1/file", "size" => 100}]
    }
  end

  defp audio(overrides \\ %{}) do
    Map.merge(
      %{
        "ratingKey" => "1965",
        "title" => "Teardrop",
        "parentRatingKey" => "1900",
        "parentTitle" => "Mezzanine",
        "grandparentTitle" => "Massive Attack",
        "duration" => 330_000,
        "index" => 3,
        "parentIndex" => 1,
        "thumb" => "/library/metadata/1900/thumb/1",
        "Media" => [
          %{
            "audioCodec" => "flac",
            "container" => "flac",
            "Part" => [%{"key" => "/library/parts/44/1/file.flac", "size" => 41_000_000}]
          }
        ]
      },
      overrides
    )
  end

  describe "the headers of a request" do
    test "they name the product, the client and the token" do
      put_link()
      stub(container([]))

      assert {:ok, _page} = Server.page(:tracks, "3", 0)

      assert_receive {:request, "GET", "/library/sections/3/all", _params, headers}

      assert headers["x-plex-product"] == "PiFi"
      assert headers["x-plex-token"] == "THETOKEN"
      assert headers["x-plex-client-identifier"] == Server.client_id()
    end

    # **A Plex server answers XML for a request that names no type.** Every read of this
    # module expects a map, so an answer of XML would give `{:error, ...}` for a server
    # that is working.
    test "they ask for JSON" do
      put_link()
      stub(container([]))

      assert {:ok, _page} = Server.page(:tracks, "3", 0)

      assert_receive {:request, "GET", _path, _params, headers}
      assert headers["accept"] == "application/json"
    end

    # **A page is a header for Plex, and a parameter for Jellyfin.** A read that put
    # these in the query would get the first page of the library every time, and the
    # sync would never finish.
    test "a page names its place in two headers" do
      put_link()
      stub(container([]))

      assert {:ok, _page} = Server.page(:albums, "3", 100)

      assert_receive {:request, "GET", _path, params, headers}

      assert headers["x-plex-container-start"] == "100"
      assert headers["x-plex-container-size"] == to_string(Server.page_size())
      assert params["type"] == "9"
    end

    test "the identifier of the client stays the same" do
      first = Server.client_id()

      assert Server.client_id() == first
    end
  end

  describe "client_id/0" do
    test "it makes one the first time, and the settings then hold it" do
      made = Server.client_id()

      assert {:ok, %{value: ^made}} = Settings.fetch(Server.client_id_setting())
    end
  end

  describe "start_link_to_account/0" do
    test "it asks plex.tv for a code, and it keeps both parts" do
      stub(%{"id" => 12_345, "code" => "ABCD"})

      assert {:ok, %{pin: "12345", code: "ABCD"}} = Server.start_link_to_account()

      assert_receive {:request, "POST", "/api/v2/pins", _params, _headers}

      assert Server.pending_code() == "ABCD"
    end

    # **A strong code is long, and plex.tv/link has four boxes.** That parameter
    # belongs to the flow that sends a person to `app.plex.tv/auth` in a browser, and
    # this device drives no browser. A measurement on a board on 2026-09-14 asked for
    # one and told a person to type it at plex.tv/link.
    test "it asks for no strong code, because plex.tv/link takes the short one" do
      stub(%{"id" => 12_345, "code" => "ABCD"})

      assert {:ok, _pin} = Server.start_link_to_account()

      assert_receive {:request, "POST", "/api/v2/pins", params, _headers}
      refute Map.has_key?(params, "strong")
    end

    # **Plex gives the identifier of a pin as a number.** A later read builds a path
    # from it, so a value that stayed a number would give `/api/v2/pins/12345` only by
    # accident of interpolation, and `Settings` takes text alone.
    test "a number for the identifier becomes text" do
      stub(%{"id" => 12_345, "code" => "ABCD"})

      assert {:ok, %{pin: pin}} = Server.start_link_to_account()
      assert is_binary(pin)
    end

    test "an answer with no code gives an error" do
      stub(%{"id" => 12_345})

      assert {:error, :no_code} = Server.start_link_to_account()
    end
  end

  describe "link_state/0" do
    test "a person who has not typed the code yet leaves it waiting" do
      Settings.put!(Server.pin_setting(), "12345")
      stub(%{"id" => 12_345, "code" => "ABCD", "authToken" => nil})

      assert {:ok, :waiting} = Server.link_state()
      assert {:error, :not_linked} = Server.account_token()
    end

    test "a token takes the link, and the code goes" do
      Settings.put!(Server.pin_setting(), "12345")
      Settings.put!(Server.code_setting(), "ABCD")
      stub(%{"id" => 12_345, "authToken" => "THEACCOUNT"})

      assert {:ok, :linked} = Server.link_state()

      assert_receive {:request, "GET", "/api/v2/pins/12345", _params, _headers}
      assert {:ok, "THEACCOUNT"} = Server.account_token()
      assert Server.pending_code() == nil
    end

    # A code lives for a few minutes, and plex.tv answers 404 for one that ran out.
    test "a code that ran out of time names itself" do
      Settings.put!(Server.pin_setting(), "12345")
      stub(%{}, status: 404)

      assert {:error, :unknown_pin} = Server.link_state()
    end

    test "a device that asked for no code says so" do
      assert {:error, :no_pin} = Server.link_state()
    end
  end

  describe "servers/0" do
    test "it gives each server of the account with a local address" do
      put_account()

      stub([
        %{
          "name" => "The study",
          "provides" => "server",
          "accessToken" => "SERVERTOKEN",
          "connections" => [
            %{"uri" => "https://relay.plex.direct", "local" => false},
            %{"uri" => "http://192.168.1.5:32400", "local" => true}
          ]
        }
      ])

      assert {:ok, [server]} = Server.servers()

      assert server.name == "The study"
      assert server.address == "http://192.168.1.5:32400"
      assert server.token == "SERVERTOKEN"
    end

    # **The relay of Plex carries the audio of a household over the internet and back.**
    # A device that used it would read its own music through a machine in another
    # country, so a server that only answers there is one that this source cannot use.
    test "a server that no local connection reaches gives no address" do
      put_account()

      stub([
        %{
          "name" => "Far away",
          "provides" => "server",
          "accessToken" => "SERVERTOKEN",
          "connections" => [%{"uri" => "https://relay.plex.direct", "local" => false}]
        }
      ])

      assert {:ok, [%{address: nil, name: "Far away"}]} = Server.servers()
    end

    # An account lists a player and a controller beside a server, and neither one holds
    # a library.
    test "a resource that is not a server is absent" do
      put_account()

      stub([
        %{
          "name" => "A phone",
          "provides" => "client,player",
          "accessToken" => "T",
          "connections" => []
        }
      ])

      assert {:ok, []} = Server.servers()
    end

    test "a device with no account token says so" do
      assert {:error, :not_linked} = Server.servers()
    end
  end

  describe "use_server/1" do
    test "it keeps the address, the token of that server and its name" do
      put_account()

      :ok =
        Server.use_server(%{name: "The study", address: @address, token: "SERVERTOKEN"})

      assert {:ok, %{address: @address, token: "SERVERTOKEN"}} = Server.link()
      assert Server.server_name() == "The study"
      assert Server.configured?()
    end
  end

  describe "sections/1" do
    test "it gives the music sections and no other" do
      put_link()

      stub(%{
        "MediaContainer" => %{
          "Directory" => [
            %{"key" => "1", "type" => "movie", "title" => "Films"},
            %{"key" => "3", "type" => "artist", "title" => "Music"},
            %{"key" => "5", "type" => "artist", "title" => "Audiobooks"}
          ]
        }
      })

      assert {:ok, ["3", "5"]} = Server.sections()
      assert_receive {:request, "GET", "/library/sections", _params, _headers}
    end

    test "a server with no music gives an empty list" do
      put_link()
      stub(%{"MediaContainer" => %{"Directory" => []}})

      assert {:ok, []} = Server.sections()
    end
  end

  describe "page/4" do
    test "a track carries its artist, its numbers, its part and its size" do
      put_link()
      stub(container([audio()], %{"totalSize" => 1}))

      assert {:ok, %{entries: [entry], count: 1, total: 1}} = Server.page(:tracks, "3", 0)

      assert entry.ref == "1965"
      assert entry.title == "Teardrop"
      assert entry.parent_ref == "1900"
      assert entry.subtitle == "Massive Attack"
      assert entry.duration_ms == 330_000
      assert entry.number == 3
      assert entry.disc == 1
      assert entry.part_key == "/library/parts/44/1/file.flac"
      assert entry.byte_size == 41_000_000
      assert entry.format == :flac
      assert entry.container_format == :none
    end

    # **Plex gives a rating key as a number in some answers and as text in others.** A
    # `parentRatingKey` of 1900 and a `ratingKey` of "1900" would name one album twice,
    # and the tree would lose every track of it.
    test "a rating key that arrives as a number becomes the same text" do
      put_link()
      stub(container([audio(%{"ratingKey" => 1965, "parentRatingKey" => 1900})]))

      assert {:ok, %{entries: [entry]}} = Server.page(:tracks, "3", 0)

      assert entry.ref == "1965"
      assert entry.parent_ref == "1900"
    end

    # **A `MediaContainer` names `totalSize` only when it has more than one page.** A
    # caller that read zero there would stop before it wrote a row, so a small section
    # would never reach the catalogue.
    test "an answer with no totalSize counts what it sent" do
      put_link()
      stub(container([audio()]))

      assert {:ok, %{total: 1, count: 1}} = Server.page(:tracks, "3", 0)
    end

    test "an album carries its artist, its year and the day the server took it in" do
      put_link()

      stub(
        container([
          %{
            "ratingKey" => "1900",
            "title" => "Mezzanine",
            "parentRatingKey" => "1800",
            "parentTitle" => "Massive Attack",
            "year" => 1998,
            "addedAt" => 1_600_000_000,
            "thumb" => "/library/metadata/1900/thumb/1"
          }
        ])
      )

      assert {:ok, %{entries: [entry]}} = Server.page(:albums, "3", 0)

      assert entry.parent_ref == "1800"
      assert entry.subtitle == "Massive Attack"
      assert entry.release_year == 1998
      assert entry.added_at == DateTime.from_unix!(1_600_000_000)
    end

    test "an album carries the record label that the server holds on studio" do
      put_link()

      stub(
        container([
          %{"ratingKey" => "1900", "title" => "Mezzanine", "studio" => "Circa"}
        ])
      )

      assert {:ok, %{entries: [entry]}} = Server.page(:albums, "3", 0)

      assert entry.record_labels == ["Circa"]
    end

    test "an album that names no record label carries none" do
      put_link()

      stub(container([%{"ratingKey" => "1900", "title" => "Mezzanine", "studio" => ""}]))

      assert {:ok, %{entries: [entry]}} = Server.page(:albums, "3", 0)

      assert entry.record_labels == []
    end

    test "an artist carries its name and its picture" do
      put_link()

      stub(
        container([
          %{"ratingKey" => "1800", "title" => "Massive Attack", "thumb" => "/art/1800"}
        ])
      )

      assert {:ok, %{entries: [entry]}} = Server.page(:artists, "3", 0)

      assert entry.ref == "1800"
      assert entry.title == "Massive Attack"
      assert entry.parent_ref == nil
      assert entry.artwork_url =~ "/photo/:/transcode?"
      assert entry.artwork_url =~ "url=%2Fart%2F1800"
    end

    # **A Plex server answers 401 for a picture that carries no token, and a Jellyfin
    # server draws one for a request that carries nothing.** A read of a real library on
    # 2026-09-14 wrote 63,010 tracks with an address that no picture came back from.
    test "the address of a picture carries the token" do
      put_link()

      stub(
        container([
          %{"ratingKey" => "1800", "title" => "Massive Attack", "thumb" => "/art/1800"}
        ])
      )

      assert {:ok, %{entries: [entry]}} = Server.page(:artists, "3", 0)

      assert entry.artwork_url =~ "X-Plex-Token=THETOKEN"
    end

    test "an item with no picture names no address" do
      put_link()
      stub(container([%{"ratingKey" => "1800", "title" => "Massive Attack"}]))

      assert {:ok, %{entries: [entry]}} = Server.page(:artists, "3", 0)
      assert entry.artwork_url == nil
    end

    test "an item with no name and one with no key cannot become a row" do
      put_link()

      stub(
        container(
          [
            %{"ratingKey" => "1", "title" => ""},
            %{"title" => "No key"},
            %{"ratingKey" => "3", "title" => "Good"}
          ],
          %{"totalSize" => 3}
        )
      )

      assert {:ok, %{entries: entries, count: 3, total: 3}} = Server.page(:artists, "3", 0)

      assert Enum.map(entries, & &1.ref) == ["3"]
    end

    test "a token that stopped working names itself" do
      put_link()
      stub(%{}, status: 401)

      assert {:error, :unauthorised} = Server.page(:tracks, "3", 0)
    end
  end

  describe "the codec of a track" do
    setup do
      put_link()
      :ok
    end

    test "the three that the pipeline reads as they are" do
      for {codec, wrapper, format} <- [
            {"flac", "flac", :flac},
            {"mp3", "mp3", :mp3},
            {"vorbis", "ogg", :vorbis}
          ] do
        stub(container([audio(%{"Media" => [media(codec, wrapper)]})]))

        assert {:ok, %{entries: [entry]}} = Server.page(:tracks, "3", 0)
        assert entry.format == format
      end
    end

    # **AAC in ADTS is read as it is, and AAC in MP4 is a conversion.** The frames of an
    # m4a file sit in a table and not in the bytes, and two boxes of an ordinary one
    # defeat the demultiplexer of the plugin, one after the other. A sample of 550
    # tracks of one real library on 2026-09-14 gave 78 of them, so this is 14% of it.
    test "AAC in ADTS is read, and AAC in MP4 converts" do
      for wrapper <- ["aac", "adts"] do
        stub(container([audio(%{"Media" => [media("aac", wrapper)]})]))
        assert {:ok, %{entries: [adts]}} = Server.page(:tracks, "3", 0)
        assert {adts.format, adts.container_format} == {:aac, :none}
      end

      for wrapper <- ["mp4", "m4a"] do
        stub(container([audio(%{"Media" => [media("aac", wrapper)]})]))
        assert {:ok, %{entries: [mp4]}} = Server.page(:tracks, "3", 0)
        assert mp4.format == :unknown
      end
    end

    test "a codec that this firmware cannot decode is unknown" do
      stub(container([audio(%{"Media" => [media("alac", "m4a")]})]))

      assert {:ok, %{entries: [entry]}} = Server.page(:tracks, "3", 0)
      assert entry.format == :unknown
    end

    # Ogg carries Vorbis and it carries FLAC, and `PiFi.Player.Pipeline` builds a
    # different graph for each, so the wrapper is a fact of its own.
    test "an Ogg wrapper says so, whatever is inside it" do
      stub(container([audio(%{"Media" => [media("flac", "ogg")]})]))

      assert {:ok, %{entries: [entry]}} = Server.page(:tracks, "3", 0)

      assert entry.format == :flac
      assert entry.container_format == :ogg
    end
  end

  describe "transcode_url/2" do
    # **A server converts for a platform that it holds a profile for.** A request that
    # named `PiFi` answered 400 on a board on 2026-09-14, and the log of the server said
    # `TranscodeUniversalRequest: unable to find a matching profile`.
    test "it names a platform that every server holds a profile for" do
      put_link()

      assert {:ok, url} = Server.transcode_url("1965")
      query = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert query["X-Plex-Platform"] == "Generic"
      assert query["X-Plex-Product"] == "PiFi"
    end

    # **A profile of two codecs lets the server choose, and a caller cannot then say
    # what it will read.** A profile of `aac,mp3` on a board on 2026-09-14 gave MPEG-TS
    # whose table named stream type 0x03, which is MP3, while the pipeline had been told
    # to expect AAC. The parser of AAC read MP3 and gave no sound and no error.
    test "it asks for one codec, so the pipeline knows what arrives" do
      put_link()

      assert {:ok, url} = Server.transcode_url("1965")
      query = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert query["protocol"] == "hls"
      assert query["X-Plex-Client-Profile-Extra"] =~ "container=mpegts"
      assert query["X-Plex-Client-Profile-Extra"] =~ "audioCodec=mp3"
      refute query["X-Plex-Client-Profile-Extra"] =~ "aac"
      assert Server.transcode_format() == :mp3
      assert String.starts_with?(url, "#{@address}/music/:/transcode/universal/start.m3u8?")
    end

    # **Every value is in the query, and no header takes part**, which is what lets
    # `PiFi.Player.Hls.resolve/2` read the address with no knowledge of Plex.
    test "it carries the token and the path of the track" do
      put_link()

      assert {:ok, url} = Server.transcode_url("1965")
      query = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert query["X-Plex-Token"] == "THETOKEN"
      assert query["path"] == "/library/metadata/1965"
      assert query["directPlay"] == "0"
    end

    # A server counts one conversion for each identifier, and a repeated one would join
    # a stream that another play is reading.
    test "each call names a session of its own" do
      put_link()

      assert {:ok, first} = Server.transcode_url("1965")
      assert {:ok, second} = Server.transcode_url("1965")

      assert session_of(first) != session_of(second)
    end

    test "a device with no link says so" do
      assert {:error, :no_address} = Server.transcode_url("1965")
    end
  end

  defp session_of(url) do
    url |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("session")
  end

  describe "stream_url/2" do
    test "it names the part of the server and it carries the token" do
      put_link()

      assert {:ok, url} = Server.stream_url("/library/parts/44/1/file.flac")

      assert url == "#{@address}/library/parts/44/1/file.flac?X-Plex-Token=THETOKEN"
    end

    test "a track with no part cannot play" do
      put_link()

      assert {:error, :no_part} = Server.stream_url(nil)
    end
  end

  describe "link/0" do
    test "a device with no server says which part is missing" do
      assert {:error, :no_address} = Server.link()

      Settings.put!(Server.address_setting(), @address)

      assert {:error, :not_linked} = Server.link()
    end
  end

  describe "forget/0" do
    # A person who links again lists one device and not two, so the identifier of the
    # client outlives the link.
    test "both tokens and the server go, and the identifier of the client stays" do
      put_account()
      put_link()
      client_id = Server.client_id()

      :ok = Server.forget()

      assert {:error, :not_linked} = Server.account_token()
      assert {:error, :no_address} = Server.address()
      refute Server.configured?()
      assert Server.client_id() == client_id
    end
  end
end
