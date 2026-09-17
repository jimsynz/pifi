defmodule PiFi.Source.PlexTest do
  use PiFi.DataCase, async: false
  use Oban.Testing, repo: PiFi.Repo

  require Ash.Query

  alias PiFi.Playback
  alias PiFi.Playback.Item
  alias PiFi.Player.Hls
  alias PiFi.Plex.Companion
  alias PiFi.Plex.Server
  alias PiFi.Settings
  alias PiFi.Source

  @address "http://plex.test:32400"

  setup do
    Application.put_env(:pifi, Server, plug: {Req.Test, Server}, retry: false)
    on_exit(fn -> Application.delete_env(:pifi, Server) end)
    :ok
  end

  defp put_account, do: Settings.put!(Server.account_setting(), "THEACCOUNT")

  defp put_link do
    Settings.put!(Server.address_setting(), @address)
    Settings.put!(Server.token_setting(), "THETOKEN")
    Settings.put!(Server.name_setting(), "The study")
    :ok
  end

  # `PiFi.Player.Hls` reads a playlist through a Req of its own, so a test of the
  # conversion gives that one a stub and not the stub of the server.
  defp stub_hls(fun) do
    Application.put_env(:pifi, Hls, plug: {Req.Test, Hls}, retry: false)
    on_exit(fn -> Application.delete_env(:pifi, Hls) end)

    Req.Test.stub(Hls, fun)
  end

  defp stub(body, options \\ []) do
    status = Keyword.get(options, :status, 200)
    test = self()

    Req.Test.stub(Server, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test, {:request, conn.method, conn.request_path, conn.params})

      Req.Test.json(Plug.Conn.put_status(conn, status), body)
    end)
  end

  defp resource(name, address) do
    %{
      "name" => name,
      "provides" => "server",
      "accessToken" => "TOKEN-#{name}",
      "connections" => connections(address)
    }
  end

  defp connections(nil), do: [%{"uri" => "https://relay.plex.direct", "local" => false}]
  defp connections(address), do: [%{"uri" => address, "local" => true}]

  defp track!(attributes) do
    Playback.upsert_item!(
      Map.merge(
        %{
          source: "plex",
          source_ref: "track-1",
          kind: :track,
          title: "Teardrop",
          transport: :download,
          format: :flac,
          container_format: :none,
          source_key: "/library/parts/44/1/file.flac",
          keeps_place?: false
        },
        attributes
      )
    )
  end

  describe "what this source says about itself" do
    test "it names its title, its icon and its kinds" do
      assert Source.Plex.title() == "Plex"
      assert Source.Plex.icon() == :plex
      assert Source.Plex.kinds() == [container: "Albums", track: "Tracks"]
    end

    # A skip works for MP3, for AAC and for FLAC, which is every codec that this source
    # can play but Vorbis. `PiFi.Player` refuses the skip when it sees that track.
    #
    # A search reaches no server: the catalogue holds the whole library, so it reads the
    # card and it works when the server is off.
    test "it offers a search and a skip" do
      assert Source.Plex.capabilities() == [:search, :skip]
    end

    # An artist and an album are both containers, so `kinds/0` cannot tell them apart.
    test "it names three groups for a search, which is finer than its kinds" do
      labels = Source.Plex.search_groups("") |> Enum.map(&elem(&1, 0))

      assert labels == ["Artists", "Albums", "Tracks"]
    end

    test "it gives six branches at the top of the tree" do
      names = Source.Plex.roots() |> Enum.map(&elem(&1, 0))

      assert names == [
               "Artists",
               "Albums",
               "Recently added",
               "Genres",
               "Record labels",
               "Favourites"
             ]
    end

    test "an album reads its tracks by their place on the record" do
      assert %{sort: [place: :asc, sorted_title: :asc], number?: true, order: {"Track", "place"}} =
               Source.Plex.listing(%{kind: :container, parent_id: nil})
    end

    # An artist row shows the year of each album, and an album row shows the length of
    # each track.
    test "a row says a different thing inside an artist and inside an album" do
      artist = Source.Plex.listing(%{kind: :container, parent_id: nil})
      album = Source.Plex.listing(%{kind: :container, parent_id: "something"})

      assert artist.facts == [:subtitle, :release_year]
      assert album.facts == [:subtitle, :duration_ms]
    end
  end

  describe "ready?/0" do
    test "a device with no link reaches nothing" do
      refute Source.Plex.ready?()

      put_link()

      assert Source.Plex.ready?()
    end
  end

  describe "settings_actions/0" do
    test "a device that never linked offers the one control that starts it" do
      assert [%{name: "link"}] = Source.Plex.settings_actions()
    end

    test "a device that asked for a code offers the control that finishes it" do
      Settings.put!(Server.pin_setting(), "12345")
      Settings.put!(Server.code_setting(), "ABCD")

      assert ["finish_link", "link"] =
               Source.Plex.settings_actions() |> Enum.map(& &1.name)
    end

    test "a device that linked the account and chose no server offers the finder" do
      put_account()

      assert ["choose_server", "remove_link"] =
               Source.Plex.settings_actions() |> Enum.map(& &1.name)
    end

    test "a device that chose a server offers the read, the player and the removal" do
      put_account()
      put_link()

      assert ["read_library", "start_player", "remove_link"] =
               Source.Plex.settings_actions() |> Enum.map(& &1.name)
    end

    # **A port is a door, so the control says what it will do and not what it is.** A
    # person who turns this on opens a port of their device. See `PiFi.Plex.Companion`.
    test "the control of the player offers the opposite of what a person chose" do
      put_account()
      put_link()

      on_exit(fn -> Companion.enable(false) end)
      Companion.enable(true)

      assert ["read_library", "stop_player", "remove_link"] =
               Source.Plex.settings_actions() |> Enum.map(& &1.name)
    end
  end

  # **A player is two things**: the device listens, and the account knows where to reach
  # it. Each answer below was measured against plex.tv on 2026-09-15. See
  # `PiFi.Plex.Server.publish_player/1`.
  describe "becoming a player" do
    # The stub answers by path, because one flow makes three requests of plex.tv.
    defp stub_player(options) do
      test = self()
      token = Keyword.get(options, :token)

      Req.Test.stub(Server, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test, {:request, conn.method, conn.request_path, conn.params})

        body =
          cond do
            conn.request_path == "/api/v2/pins" ->
              %{"id" => 999, "code" => "WXYZ"}

            String.starts_with?(conn.request_path, "/api/v2/pins/") ->
              %{"authToken" => token}

            conn.request_path == "/api/v2/devices" ->
              [%{"clientIdentifier" => Server.client_id(), "id" => 4242}]

            true ->
              %{}
          end

        Req.Test.json(conn, body)
      end)
    end

    test "a device that never asked offers the control that starts it" do
      put_account()
      put_link()

      assert "start_player" in (Source.Plex.settings_actions() |> Enum.map(& &1.name))
    end

    test "it asks plex.tv for a code, and it tells a person where to type it" do
      stub_player([])

      assert {:ok, message} = Source.Plex.run_settings_action("start_player")

      assert message =~ "WXYZ"
      assert message =~ "plex.tv/link"
      assert Server.player_code() == "WXYZ"
    end

    # **A device that names no `X-Plex-Provides` is not a player.** A measurement linked
    # this device with no such header and plex.tv listed it nowhere at all.
    test "the request says that this device is a player" do
      stub_player([])

      Source.Plex.run_settings_action("start_player")

      assert_receive {:request, "POST", "/api/v2/pins", _params}
      assert Server.player_provides() == "client,player,pubsub-player"
    end

    test "a device that asked for a code offers the control that finishes it" do
      put_account()
      put_link()
      Settings.put!(Server.player_code_setting(), "WXYZ")

      [control] = Source.Plex.settings_actions() |> Enum.filter(&(&1.name == "finish_player"))

      assert control.description =~ "WXYZ"
    end

    # **A code that ran out of time must go.** The control of a person reads the code
    # that waits, so a code that stayed offered them the end of a link that could never
    # finish, and the control that starts a new one was not there to press. A board held
    # a person in that corner on 2026-09-15.
    test "a code that ran out of time leaves, so a person may start again" do
      put_account()
      put_link()
      stub_player([])
      Source.Plex.run_settings_action("start_player")
      assert Server.player_code() == "WXYZ"

      Req.Test.stub(Server, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert {:error, message} = Source.Plex.run_settings_action("finish_player")

      assert message =~ "ran out of time"
      assert Server.player_code() == nil
      assert "start_player" in (Source.Plex.settings_actions() |> Enum.map(& &1.name))
    end

    # **A device that is a player already asks no person to authorise it again.** The
    # account holds the row for as long as a person leaves it there.
    test "a device that is a player already opens the port and asks for no code" do
      put_account()
      put_link()
      Settings.put!("plex_device_id", "4242")
      on_exit(fn -> Companion.enable(false) end)

      stub_player([])

      assert {:ok, message} = Source.Plex.run_settings_action("start_player")

      assert message =~ "Plex player now"
      refute_received {:request, "POST", "/api/v2/pins", _params}
      assert Companion.enabled?()
    end

    test "a person who has not typed the code yet reads it again" do
      stub_player([])
      Source.Plex.run_settings_action("start_player")

      assert {:error, message} = Source.Plex.run_settings_action("finish_player")

      assert message =~ "WXYZ"
    end

    # **The endpoint that publishes an address is the old one.** `/api/v2/devices/{id}`
    # answers 200 and writes nothing.
    test "a code that a person typed publishes the address of the player" do
      on_exit(fn -> Companion.enable(false) end)
      stub_player(token: "THETOKEN")
      Source.Plex.run_settings_action("start_player")

      assert {:ok, message} = Source.Plex.run_settings_action("finish_player")

      assert message =~ "Plex player now"
      assert_receive {:request, "PUT", "/devices/4242.xml", params}
      assert params["Connection"] |> hd() |> Map.get("uri") =~ ":#{Companion.port()}"
      assert Companion.enabled?()
      assert Server.player_code() == nil
    end
  end

  describe "the link" do
    test "it asks plex.tv for a code, and it tells a person where to type it" do
      stub(%{"id" => 12_345, "code" => "ABCD"})

      assert {:ok, message} = Source.Plex.run_settings_action("link")

      assert message =~ "ABCD"
      assert message =~ "plex.tv/link"
    end

    test "a person who has not typed the code yet reads the code again" do
      Settings.put!(Server.pin_setting(), "12345")
      Settings.put!(Server.code_setting(), "ABCD")
      stub(%{"id" => 12_345, "authToken" => nil})

      assert {:ok, message} = Source.Plex.run_settings_action("finish_link")

      assert message =~ "ABCD"
    end

    test "a code that ran out of time asks a person to start again" do
      Settings.put!(Server.pin_setting(), "12345")
      Settings.put!(Server.code_setting(), "ABCD")
      stub(%{}, status: 404)

      assert {:error, message} = Source.Plex.run_settings_action("finish_link")

      assert message =~ "ran out of time"
      assert Server.pending_code() == nil
    end

    test "a person who presses Finish linking first is told to link first" do
      assert {:error, message} = Source.Plex.run_settings_action("finish_link")

      assert message =~ "Link this account"
    end
  end

  describe "finding the server" do
    # A household with one server never chooses, and that is almost every household.
    test "a code that a person typed takes the one server of the account" do
      Settings.put!(Server.pin_setting(), "12345")

      Req.Test.stub(Server, fn conn ->
        case conn.request_path do
          "/api/v2/pins/12345" -> Req.Test.json(conn, %{"authToken" => "THEACCOUNT"})
          "/api/v2/resources" -> Req.Test.json(conn, [resource("The study", @address)])
        end
      end)

      assert {:ok, message} = Source.Plex.run_settings_action("finish_link")

      assert message =~ "The study"
      assert Server.configured?()
      assert {:ok, %{address: @address, token: "TOKEN-The study"}} = Server.link()
    end

    # A household with two reads which other name it can type into Server name.
    # **A person who names their server wants their music, and presses nothing more.**
    # An earlier version wrote the server and said that it read the library, and it
    # queued nothing: a board named the server and then said 0 tracks.
    test "naming the server starts the read of the library" do
      put_account()
      stub([resource("The study", @address)])

      assert {:ok, _message} = Source.Plex.run_settings_action("choose_server")

      assert_enqueued(worker: PiFi.Plex.Sync.Workers.Library)
    end

    test "a household with two servers reads the name of the other one" do
      put_account()
      stub([resource("The study", @address), resource("The shed", "http://shed.test:32400")])

      assert {:ok, message} = Source.Plex.run_settings_action("choose_server")

      assert message =~ "also lists The shed"
    end

    test "a person names the server that holds their music" do
      put_account()
      stub([resource("The study", @address), resource("The shed", "http://shed.test:32400")])

      assert {:ok, _message} = Source.Plex.put_settings(%{"server_name" => "The shed"})

      assert {:ok, %{address: "http://shed.test:32400"}} = Server.link()
    end

    test "a name that the account does not list says so" do
      put_account()
      stub([resource("The study", @address)])

      assert {:error, message} = Source.Plex.put_settings(%{"server_name" => "The attic"})

      assert message =~ "The attic"
    end

    # **A server that only answers through the relay carries the audio of a household
    # over the internet and back.** A person reads what their account lists, so they can
    # see which machine is off.
    test "no server on this network says which ones the account lists" do
      put_account()
      stub([resource("Far away", nil)])

      assert {:error, message} = Source.Plex.run_settings_action("choose_server")

      assert message =~ "Far away"
      assert message =~ "same network"
    end

    test "an account that lists no server at all says so" do
      put_account()
      stub([])

      assert {:error, message} = Source.Plex.run_settings_action("choose_server")

      assert message =~ "lists no server"
    end

    test "an empty name gives the device the first server that answers" do
      put_account()
      Settings.put!(Server.name_setting(), "The shed")

      assert {:ok, message} = Source.Plex.put_settings(%{"server_name" => "  "})

      assert message =~ "first server"
      assert Server.server_name() == nil
    end
  end

  describe "remove_link" do
    test "both tokens and the server go, and the music stays in the list" do
      put_account()
      put_link()
      track!(%{})

      assert {:ok, message} = Source.Plex.run_settings_action("remove_link")

      assert message =~ "not linked"
      refute Server.configured?()
      assert [_track] = Item |> Ash.Query.filter(source == "plex") |> Ash.read!()
    end
  end

  describe "resolve/1" do
    test "a track gives the address of its file, with the token behind it" do
      put_link()
      track = track!(%{})

      assert {:ok, playable} = Source.Plex.resolve(track)

      assert playable.uri == "#{@address}/library/parts/44/1/file.flac?X-Plex-Token=THETOKEN"
      assert playable.transport == :download
      assert playable.format == :flac
      assert playable.container == :none
      refute playable.live?
    end

    # Ogg carries Vorbis and it carries FLAC, and `PiFi.Player.Pipeline` builds a
    # different graph for each, so the wrapper reaches the player.
    test "a track in Ogg says so" do
      put_link()
      track = track!(%{source_ref: "track-ogg", format: :vorbis, container_format: :ogg})

      assert {:ok, %{container: :ogg, format: :vorbis}} = Source.Plex.resolve(track)
    end

    # **A codec that the pipeline cannot read is one that the server converts.** The
    # master playlist names one variant, and the media playlist behind it is what the
    # pipeline reads.
    test "a codec that this firmware cannot decode asks the server to convert" do
      put_link()
      track = track!(%{source_ref: "track-alac", format: :unknown, transport: :hls})

      stub_hls(fn conn ->
        if String.ends_with?(conn.request_path, "start.m3u8") do
          Req.Test.text(conn, "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=320000\nbase/index.m3u8\n")
        else
          Req.Test.text(
            conn,
            "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n" <>
              "#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:1.0,\n00000.ts\n#EXT-X-ENDLIST\n"
          )
        end
      end)

      assert {:ok, playable} = Source.Plex.resolve(track)

      assert playable.transport == :hls
      assert playable.container == :mpeg_ts
      assert playable.format == :mp3
      assert playable.uri =~ "base/index.m3u8"
      refute playable.live?
    end

    test "a conversion that the server refuses gives an error" do
      put_link()
      track = track!(%{source_ref: "track-alac2", format: :unknown, transport: :hls})

      stub_hls(fn conn -> Plug.Conn.send_resp(conn, 400, "") end)

      assert {:error, _reason} = Source.Plex.resolve(track)
    end

    test "a track that no read has filled in yet names itself" do
      put_link()
      track = track!(%{source_ref: "track-empty", source_key: nil})

      assert {:error, {:not_read_yet, "Teardrop"}} = Source.Plex.resolve(track)
    end

    test "a container does not play" do
      put_link()

      container =
        Playback.upsert_item!(%{
          source: "plex",
          source_ref: "album-1",
          kind: :container,
          title: "Mezzanine"
        })

      assert {:error, {:not_a_track, _id}} = Source.Plex.resolve(container)
    end

    # A caller that reads many tracks reads the link once, so a loop of an album makes
    # one read of the settings and not three for each track.
    test "a caller that read the link already passes it" do
      put_link()
      {:ok, link} = Server.link()
      track = track!(%{})

      assert {:ok, %{uri: uri}} = Source.Plex.resolve(track, link)

      assert uri =~ "X-Plex-Token=THETOKEN"
    end
  end

  describe "settings/0" do
    test "it offers the name of the server, and it says what the state is" do
      assert [field] = Source.Plex.settings()

      assert field.key == "server_name"
      assert field.type == :text
      assert field.description =~ "not linked yet"
    end

    test "a device that is waiting reads the code in the description" do
      Settings.put!(Server.pin_setting(), "12345")
      Settings.put!(Server.code_setting(), "ABCD")

      assert [%{description: description}] = Source.Plex.settings()

      assert description =~ "ABCD"
      assert description =~ "plex.tv/link"
    end

    test "a device that linked the account and chose no server is told what to press" do
      put_account()

      assert [%{description: description}] = Source.Plex.settings()

      assert description =~ "Find my server"
    end

    test "a linked device reads the server that it uses and how many tracks it has" do
      put_link()
      track!(%{})

      assert [%{description: description, value: "The study"}] = Source.Plex.settings()

      assert description =~ "The study"
      assert description =~ "The library has 1 track"
    end
  end

  describe "run_settings_action/1" do
    test "a name that this source has no control for says so" do
      assert {:error, message} = Source.Plex.run_settings_action("something")

      assert message =~ "no such control"
    end
  end
end
