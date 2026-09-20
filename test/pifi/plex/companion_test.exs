defmodule PiFi.Plex.CompanionTest do
  use PiFi.DataCase, async: false

  doctest PiFi.Plex.Companion, import: true

  alias PiFi.Device.Identity
  alias PiFi.Event
  alias PiFi.Playback
  alias PiFi.Plex.Companion
  alias PiFi.Plex.Companion.Router
  alias PiFi.Plex.Server
  alias PiFi.Settings
  alias PiFi.Source
  alias PiFi.Test.PlayingPipeline
  alias PiFi.Test.SilentOutput

  # **This calls the router and it opens no port.** `Plug.Test` builds the connection,
  # so a test reads the answers of a controller with no listener at all, and a suite
  # that ran on a build agent needs no port of it.
  import Plug.Test
  import Plug.Conn

  setup do
    # `PiFi.Player` is one process for the whole node, so a track that one test plays
    # is a track that the next one reads. See `PiFiWeb.BrowseLiveTest`.
    #
    # **A control of that player answers before it does the work**, and the work writes
    # the settings and the card. A test that ended while that work was in flight left it
    # writing to a sandbox that had gone, and the database of another test then answered
    # `Database busy`. `state/0` is a call, so it waits for the work that is already
    # running, and it is the one line that drains the player. See `PiFi.Player`.
    drain = fn ->
      PiFi.Player.stop()
      PiFi.Player.state()
    end

    drain.()
    on_exit(drain)

    # **A test that turns the player on leaves a listener and an announcement behind**,
    # and both are registered by the name of their module, so the next test that starts
    # one of them meets `:already_started`. This gives every test a device that holds
    # neither.
    on_exit(fn ->
      Companion.enable(false)

      case Settings.fetch(Companion.enabled_key()) do
        {:ok, setting} -> Settings.delete!(setting)
        {:error, _reason} -> :ok
      end
    end)

    :ok
  end

  defp call(path) do
    :get
    |> conn(path)
    |> Router.call(Router.init([]))
  end

  defp poll(command_id), do: call("/player/timeline/poll?commandID=#{command_id}")

  defp attribute(body, element, name) do
    case Regex.run(~r/<#{element}([^>]*)\/>/, body) do
      [_whole, attributes] ->
        case Regex.run(~r/#{name}="([^"]*)"/, attributes) do
          [_whole, value] -> value
          nil -> nil
        end

      nil ->
        nil
    end
  end

  # **A port is a door, so this is off until a person says otherwise.** It is the
  # opposite of a source, and `PiFi.Plex.Companion` says why.
  describe "whether a person turned the player on" do
    test "a device that no person changed holds the port closed" do
      refute Companion.enabled?()
    end

    # **These read the answer of a person and not the listener.** `enable/1` also starts
    # a listener and an announcement, and those two reach the network and the card. A
    # test of a boolean that started them left a process doing the work of a test that
    # had finished, and the connection of the database went with it.
    test "a person turns it on, and the answer stays" do
      Settings.put!(Companion.enabled_key(), "true")

      assert Companion.enabled?()
    end

    test "a person turns it off again" do
      Settings.put!(Companion.enabled_key(), "true")
      Settings.put!(Companion.enabled_key(), "false")

      refute Companion.enabled?()
    end

    # One test starts the real listener, because the answer of a person is worth nothing
    # if the port stays shut.
    test "the control opens the port and closes it again" do
      Companion.enable(true)
      assert Companion.running?()

      Companion.enable(false)
      refute Companion.running?()
    end
  end

  describe "the resources of this player" do
    test "it names what a controller needs to draw a player" do
      body = call("/resources").resp_body

      assert attribute(body, "Player", "machineIdentifier")
      assert attribute(body, "Player", "title")
      assert attribute(body, "Player", "product") == "PiFi"
      assert attribute(body, "Player", "protocol") == "plex"
      assert attribute(body, "Player", "protocolVersion")
      assert attribute(body, "Player", "deviceClass")
    end

    # **The capabilities decide which controls a person sees**, so a name that this
    # player does not answer would give them a control that does nothing.
    test "it names the capabilities that it answers, and no navigation" do
      assert Companion.capabilities() == "timeline,playback,playqueues,playqueues-creation"
      refute Companion.capabilities() =~ "navigation"
    end

    test "the answer is XML" do
      conn = call("/resources")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/xml"
      assert conn.resp_body =~ ~s(<MediaContainer size="1">)
    end
  end

  # Each of these reads what Plexamp 4.13.2 answered on 2026-09-15. See the moduledoc
  # of `PiFi.Plex.Companion.Router`.
  describe "the timeline" do
    test "the bare path of that name is not one that a player holds" do
      assert call("/timeline/poll").status == 404
    end

    # A real player answers 400 for a poll that names no number, and a controller counts
    # that number up and reads the answers against it.
    test "a poll that names no commandID is refused" do
      assert call("/player/timeline/poll").status == 400
    end

    test "the answer names the commandID of the request, and no size" do
      body = poll("7").resp_body

      assert body =~ ~s(commandID="7")
      refute body =~ ~s(size=)
    end

    # **A track that holds the player and makes no sound yet is buffering, and it is not
    # stopped.** The player reads the service of the source and builds a pipeline before
    # the first sound, and a Plex track that the server converts takes seconds over it. A
    # controller that read `stopped` there took it for the end of the music and told the
    # player to stop.
    test "a track that makes no sound yet reads as buffering" do
      state = %{playing_a_plex_track() | playing?: false, paused?: false}

      assert attribute(Router.timeline("1", state), "Timeline", "state") == "buffering"
    end

    test "a device that holds no track at all reads as stopped" do
      state = %{playing_a_plex_track() | item: nil, playing?: false, paused?: false}

      assert attribute(Router.timeline("1", state), "Timeline", "state") == "stopped"
    end

    test "a device that plays nothing says that it is stopped" do
      body = poll("1").resp_body

      assert attribute(body, "Timeline", "type") == "music"
      assert attribute(body, "Timeline", "state") in ["stopped", "paused"]
    end

    # A controller draws one element for each kind of media, because a player may hold
    # a film and a song at once. This one holds music, and it says so of the others.
    test "it names the three kinds of media" do
      body = poll("1").resp_body

      assert body =~ ~s(type="music")
      assert body =~ ~s(type="video")
      assert body =~ ~s(type="photo")
    end

    # **A real player drops `skipNext` when it holds nothing to play next**, and a
    # controller reads this list to decide which controls to draw.
    test "a device that holds nothing names the level and no other control" do
      assert attribute(poll("1").resp_body, "Timeline", "controllable") == "volume"
    end

    test "it never names a control that this firmware does not hold" do
      list = attribute(poll("1").resp_body, "Timeline", "controllable")

      for absent <- ["shuffle", "repeat", "stepBack", "stepForward"] do
        refute list =~ absent
      end
    end
  end

  describe "a command" do
    # A real player answers 200 with no body at all, and a controller reads the timeline
    # for the state that follows.
    test "each one answers with no body, and a controller reads the timeline" do
      for path <- [
            "/player/playback/pause",
            "/player/playback/stop",
            "/player/playback/skipNext",
            "/player/playback/skipPrevious",
            "/player/playback/setParameters"
          ] do
        conn = call(path)

        assert conn.status == 200
        assert conn.resp_body == ""
      end
    end

    # A person holding a telephone has nowhere to read a reason, so a command that
    # cannot happen says so in the log and answers in the ordinary way.
    test "a command that names no track answers, and it plays nothing" do
      conn = call("/player/playback/playMedia")

      assert conn.status == 200
    end

    test "a command that names a track of no library answers" do
      conn = call("/player/playback/playMedia?key=/library/metadata/404")

      assert conn.status == 200
    end

    # **A player that answered every path would say that it holds a control that does
    # nothing.** A real player answers 404, and `protocolCapabilities` names no
    # navigation for the same reason.
    test "a path that this player does not hold answers 404" do
      assert call("/player/navigation/moveUp").status == 404
    end

    # **A line of the log for each request fills the log of the device.** A controller
    # asked a board for this path 1020 times on 2026-09-15, and those lines pushed every
    # error out of a ring that holds 1024. `config/target.exs` keeps a device at `info`,
    # so a path that no player serves must say nothing at that level.
    test "a path that no player serves says nothing that a device keeps" do
      assert Router.level_of("/library/metadata/470959") == :debug
      assert call("/library/metadata/470959").status == 404
    end

    # A control that a controller wanted is worth a line, because it names the thing
    # that this player has still to answer.
    test "a control that this player has not is worth a line" do
      assert Router.level_of("/player/playback/stepForward") == :info
    end
  end

  # **An element that names one attribute twice is not XML, and a parser may refuse the
  # whole of it.** A board answered a timeline with `protocol="plex"` and
  # `protocol="https"` in one element on 2026-09-15, because the state of the player and
  # the address of the server each named that word. A controller then asked the player
  # for the metadata of the track, again and again, because it could not read where the
  # media was.
  describe "the XML that this player writes" do
    test "no element of an idle player names an attribute twice" do
      for path <- ["/resources", "/player/timeline/poll?commandID=1"] do
        assert_names_once(call(path).resp_body, path)
      end
    end

    # **Only a state that holds a track of a library reaches the attributes of the
    # server**, and those are the ones that collided. The settings stand in for the
    # link, so this reads no network.
    test "no element of a player that holds a track of a library names an attribute twice" do
      Settings.put!(Server.address_setting(), "https://plex.test:32400")
      Settings.put!(Server.token_setting(), "THETOKEN")
      Settings.put!("plex_machine_id", "abc123")

      body = Router.timeline("1", playing_a_plex_track())

      assert body =~ "abc123"
      assert body =~ "plex.test"
      assert_names_once(body, "timeline")
    end
  end

  defp playing_a_plex_track do
    %{
      item: %PiFi.Playback.Item{source_ref: "470959", duration_ms: 281_797, title: "A track"},
      source: PiFi.Source.Plex,
      live?: false,
      playing?: true,
      paused?: false,
      standby?: false,
      position_ms: 1000,
      artwork_path: nil,
      stream_title: nil
    }
  end

  defp assert_names_once(body, where) do
    for [_whole, attributes] <- Regex.scan(~r/<[A-Za-z]+([^>]*)\/>/, body) do
      names = ~r/([A-Za-z]+)="/ |> Regex.scan(attributes) |> Enum.map(&List.last/1)
      twice = names -- Enum.uniq(names)

      assert twice == [], "#{where} names an attribute twice: #{inspect(twice)}"
    end
  end

  # **A device that a controller drives leaves standby and it takes the switch with
  # it.** A person who hears their record and then walks to the device must find it
  # where the music is.
  describe "a device that a controller wakes" do
    setup do
      Source.enable(Source.Plex, true)
      Settings.put!(Server.address_setting(), "https://plex.test:32400")
      Settings.put!(Server.token_setting(), "THETOKEN")

      item =
        Playback.upsert_item!(%{
          source: "plex",
          source_ref: "470959",
          kind: :track,
          title: "Unshakeable",
          transport: :download,
          format: :flac,
          container_format: :none,
          source_key: "/library/parts/1/1/file.flac",
          keeps_place?: false
        })

      on_exit(fn -> PiFi.Player.standby(false) end)

      %{item: item}
    end

    test "a play of a controller takes the device out of standby" do
      PiFi.Player.standby(true)
      assert %{standby?: true} = Playback.state!()

      call("/player/playback/playMedia?key=/library/metadata/470959")

      refute Playback.state!().standby?
    end

    # `PiFi.Source.chosen/0` is the switch of the device, and a page with no source in
    # its address reads it.
    test "the switch of the device moves to Plex" do
      Source.choose(Source.InternetRadio)

      call("/player/playback/playMedia?key=/library/metadata/470959")

      assert Source.chosen() == Source.Plex
    end

    test "a command that plays nothing leaves the switch where it was" do
      Source.choose(Source.InternetRadio)

      call("/player/playback/playMedia?key=/library/metadata/404")

      assert Source.chosen() == Source.InternetRadio
    end
  end

  # **A controller asks the player to put the metadata of the track in the timeline**,
  # and it draws the title, the record, the artist and the artwork from it. A timeline
  # with none gave Plexamp nothing to draw on 2026-09-15: an empty screen and a spinner.
  describe "the metadata of the track that plays" do
    test "a timeline that a controller asked for it holds the element of the server" do
      body = Router.timeline("1", playing_a_plex_track(), ~s(<Track ratingKey="470959" />))

      assert body =~ ~s(<Track ratingKey="470959" />)
      # The timeline holds it, so that element cannot close itself.
      assert body =~ ~s(</Timeline>)
    end

    test "a timeline that no controller asked for it closes itself and holds none" do
      body = Router.timeline("1", playing_a_plex_track())

      refute body =~ "Track"
      refute body =~ "</Timeline>"
    end

    # A real player writes the element of the server inside the timeline, with the
    # `Media` and the `Part` of it. This firmware writes no part of that shape.
    test "the element of the server goes in as it arrived" do
      inside = ~s(<Track title="A song"><Media id="1"><Part id="2" /></Media></Track>)

      assert Router.timeline("1", playing_a_plex_track(), inside) =~ inside
    end
  end

  # **A controller holds the poll open until something changes.** `wait=1` is what asks,
  # and a player that answered at once turned a controller into a loop: a board answered
  # 25 polls in the few seconds that a probe watched on 2026-09-15.
  describe "a poll that waits" do
    test "a poll that names no wait answers at once" do
      {microseconds, conn} = :timer.tc(fn -> call("/player/timeline/poll?commandID=1") end)

      assert conn.status == 200
      assert microseconds < 1_000_000
    end

    # Every change that a controller draws publishes an event of the player, so the
    # answer follows the change and not the clock.
    test "a poll that waits answers as soon as the player says something" do
      task = Task.async(fn -> call("/player/timeline/poll?wait=1&commandID=2") end)

      # The subscription of the poll happens in that task, so this waits for it.
      Process.sleep(100)
      Event.publish(:player, %PiFi.Event.Player.Stopped{reason: :requested})

      {microseconds, conn} = :timer.tc(fn -> Task.await(task, 10_000) end)

      assert conn.status == 200
      assert microseconds < 4_000_000
    end
  end

  # **A controller asks for a handful of tracks and a library holds tens of thousands.**
  # A read of the whole source and a filter in memory made a board give up: it read
  # 63,010 rows of a table of 137,575, and the connection of the database stopped after
  # 15 seconds with `interrupted`. These read the statement that reaches the card.
  describe "how this player finds the tracks of a command" do
    setup do
      Source.enable(Source.Plex, true)

      for ref <- ["1", "2", "3"] do
        Playback.upsert_item!(%{
          source: "plex",
          source_ref: ref,
          kind: :track,
          title: "Track " <> ref,
          transport: :download,
          format: :flac,
          container_format: :none,
          source_key: "/library/parts/#{ref}/1/file.flac",
          keeps_place?: false
        })
      end

      :ok
    end

    # **The name of the column is in the list that every read selects**, so the test
    # must read the part that chooses the rows and not the whole statement.
    test "it asks the database for the one track that a command names" do
      sql = statement_of(fn -> call("/player/playback/playMedia?key=/library/metadata/2") end)

      [_columns, chooses] = String.split(sql, " WHERE ", parts: 2)

      assert chooses =~ "source_ref"
    end

    test "a track that this device does not hold plays nothing" do
      assert call("/player/playback/playMedia?key=/library/metadata/404").status == 200
      assert Playback.state!().item == nil
    end
  end

  # The first statement of `playback_items` that a call makes. A read of the whole
  # source names no reference, and a read of one track names it.
  defp statement_of(fun) do
    Process.register(self(), :companion_probe)
    handler = "companion-#{:erlang.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:pifi, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if metadata[:source] == "playback_items",
          do: send(:companion_probe, {:sql, metadata[:query]})
      end,
      nil
    )

    try do
      fun.()

      receive do
        {:sql, sql} -> sql
      after
        1000 -> flunk("No statement of `playback_items` reached the telemetry event.")
      end
    after
      :telemetry.detach(handler)
      Process.unregister(:companion_probe)
    end
  end

  # **A registration that says the wrong thing is worse than none**, because a
  # controller draws the player and the command then reaches an address that answers
  # nothing. See `PiFi.Plex.Companion.Announcement`.
  describe "keeping the registration current" do
    setup do
      test = self()

      # **A stub answers nothing until `Req` is told to use it.** Without this the
      # requests of these tests left the machine for plex.tv, which answered 401 because
      # they carry no token, and the test read that as a player that published nothing.
      Application.put_env(:pifi, Server, plug: {Req.Test, Server}, retry: false)
      on_exit(fn -> Application.delete_env(:pifi, Server) end)

      # **The announcement is a process of its own, and a stub of Req belongs to the
      # process that set it.** Shared mode is what lets another process read it, in the
      # way that `PiFi.Playback.FavouriteAudioTest` does.
      Req.Test.set_req_test_from_context(%{async: false})

      Req.Test.stub(Server, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test, {:request, conn.method, conn.request_path, conn.params})

        # The token of the account is a header and not a parameter, and a request that
        # carries none is the bug that this describe block exists to catch.
        send(test, {:headers, Map.new(conn.req_headers)})

        body =
          if conn.request_path == "/api/v2/devices",
            do: [%{"clientIdentifier" => Server.client_id(), "id" => 4242}],
            else: %{}

        Req.Test.json(conn, body)
      end)

      :ok
    end

    # **Every call of plex.tv carries the token of the account, and two of them did
    # not.** `headers/2` writes `x-plex-token` as the empty string for a `nil`, so the
    # publish asked plex.tv anonymously and plex.tv answered 401: the device published
    # no address and Plexamp listed no player. A measurement on the board on 2026-09-21
    # gave 401 without it and 200 with it.
    test "the publish carries the token of the account" do
      Settings.put!("plex_device_id", "4242")
      Settings.put!("plex_account_token", "a-real-token")

      start_supervised!(PiFi.Plex.Companion.Announcement)

      assert_receive {:request, "PUT", "/devices/4242.xml", _params}, 2000
      assert_receive {:headers, headers}, 2000
      assert headers["x-plex-token"] == "a-real-token"
    end

    # A device that a person never linked has no token, and asking plex.tv anonymously
    # is how this failed silently in the first place.
    test "a device with no token publishes nothing" do
      Settings.put!("plex_device_id", "4242")

      case Settings.fetch("plex_account_token") do
        {:ok, setting} -> Settings.delete!(setting)
        {:error, _reason} -> :ok
      end

      pid = start_supervised!(PiFi.Plex.Companion.Announcement)

      Process.sleep(50)

      refute_received {:request, "PUT", _path, _params}
      assert Process.alive?(pid)
    end

    test "it publishes the address when it starts, so a device that moved corrects it" do
      Settings.put!("plex_device_id", "4242")
      Settings.put!("plex_account_token", "a-real-token")

      start_supervised!(PiFi.Plex.Companion.Announcement)

      assert_receive {:request, "PUT", "/devices/4242.xml", _params}, 2000
    end

    # A person renames their device, and plex.tv holds the name of the last publish.
    test "a device that a person renames says so" do
      Settings.put!("plex_device_id", "4242")
      Settings.put!("plex_account_token", "a-real-token")

      start_supervised!(PiFi.Plex.Companion.Announcement)
      assert_receive {:request, "PUT", "/devices/4242.xml", _params}, 2000

      Event.publish(:device, %PiFi.Event.Device.IdentityChanged{
        name: "The kitchen",
        splash_path: nil
      })

      assert_receive {:request, "PUT", "/devices/4242.xml", _params}, 2000
    end

    # **`PiFi.Application` starts this at the boot and Wi-Fi is not up then**, so the
    # first publish of a cold boot carried no address and the account held a player
    # that a telephone could not reach. Nothing corrected it, because a rename is rare
    # and a restart is rarer.
    test "an address that arrives after the boot is published" do
      Settings.put!("plex_device_id", "4242")
      Settings.put!("plex_account_token", "a-real-token")

      start_supervised!(PiFi.Plex.Companion.Announcement)
      assert_receive {:request, "PUT", "/devices/4242.xml", _params}, 2000

      Event.publish(:device, %PiFi.Event.Device.NetworkChanged{
        interfaces: [%{name: "wlan0", addresses: ["192.168.3.142"]}]
      })

      assert_receive {:request, "PUT", "/devices/4242.xml", _params}, 2000
    end

    # **A device that no person linked has no row of the account to publish to**, and
    # this asks plex.tv nothing to find that out.
    test "a device that no person made a player asks plex.tv nothing" do
      pid = start_supervised!(PiFi.Plex.Companion.Announcement)

      Event.publish(:device, %PiFi.Event.Device.IdentityChanged{
        name: "A name",
        splash_path: nil
      })

      Process.sleep(50)

      refute_received {:request, _method, _path, _params}
      assert Process.alive?(pid)
    end
  end

  # **A controller does not always name a queue that exists.** It asks the player to
  # make one instead, and a board answered 404 for that on 2026-09-15:
  # `A Plex controller asked this player for GET /player/playback/createPlayQueue`.
  describe "a controller that asks this player to make a queue" do
    setup do
      # **This block plays, so it needs a pipeline and an output that make no sound.**
      # `PiFi.Output.Alsa` lists the cards of the machine, and a build agent holds
      # none, so a play without these reads `:no_output_device` and the timeline below
      # names no queue.
      PlayingPipeline.use_it()
      SilentOutput.use_it()

      Source.enable(Source.Plex, true)
      Application.put_env(:pifi, Server, plug: {Req.Test, Server}, retry: false)
      on_exit(fn -> Application.delete_env(:pifi, Server) end)
      Req.Test.set_req_test_from_context(%{async: false})

      Settings.put!(Server.address_setting(), "https://plex.test:32400")
      Settings.put!(Server.token_setting(), "THETOKEN")

      for ref <- ["11", "12"] do
        Playback.upsert_item!(%{
          source: "plex",
          source_ref: ref,
          kind: :track,
          title: "Track " <> ref,
          transport: :download,
          format: :flac,
          container_format: :none,
          source_key: "/library/parts/#{ref}/1/file.flac",
          keeps_place?: false
        })
      end

      test = self()

      Req.Test.stub(Server, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test, {:request, conn.method, conn.request_path, conn.params})

        Req.Test.json(conn, %{
          "MediaContainer" => %{
            "playQueueID" => 26_058,
            "playQueueVersion" => 3,
            "playQueueSelectedItemOffset" => 1,
            "Metadata" => [
              %{"ratingKey" => "11", "playQueueItemID" => 900},
              %{"ratingKey" => "12", "playQueueItemID" => 901}
            ]
          }
        })
      end)

      :ok
    end

    test "it asks the server to make the queue, and it plays what comes back" do
      conn = call("/player/playback/createPlayQueue?uri=server://abc/library/metadata/9")

      assert conn.status == 200
      assert_receive {:request, "POST", "/playQueues", params}
      assert params["uri"] == "server://abc/library/metadata/9"
      assert params["type"] == "music"

      # The second track of the queue, because the server named that place.
      assert Playback.state!().item.source_ref == "12"
    end

    # The switch of the device follows the music, in the way that it does for a play.
    test "the switch of the device moves to Plex" do
      Source.choose(Source.InternetRadio)

      call("/player/playback/createPlayQueue?uri=server://abc/library/metadata/9")

      assert Source.chosen() == Source.Plex
    end

    test "a command that names no address plays nothing" do
      assert call("/player/playback/createPlayQueue").status == 200
      refute_received {:request, "POST", "/playQueues", _params}
    end

    # **A controller draws its screen from the queue and not from the track.** A person
    # cast a playlist on 2026-09-15, the music played, and the telephone of that person
    # showed a spinner, because the timeline named the track and no queue.
    test "the timeline then names the queue that the controller asked for" do
      start_supervised!(PiFi.Plex.Companion.Queue)

      call("/player/playback/createPlayQueue?uri=server://abc/library/metadata/9")

      body = poll("5").resp_body

      assert body =~ ~s(playQueueID="26058")
      assert body =~ ~s(containerKey="/playQueues/26058")
      assert body =~ ~s(playQueueVersion="3")
      # The second track of the queue is the one that plays, so its row is the one named.
      assert body =~ ~s(playQueueItemID="901")
    end

    # **A track that no controller asked for still needs a queue.** A person plays a
    # record from the page of the device, or the device comes back from a restart with
    # the track that it held, and then a controller reaches it. A track with no queue
    # left that controller waiting.
    test "a track that no controller asked for gets a queue made for it" do
      # The address of the queue names the machine that holds the music.
      Settings.put!("plex_machine_id", "abc123")
      start_supervised!(PiFi.Plex.Companion.Queue)

      # The device plays it, and no controller named a queue for it.
      call("/player/playback/playMedia?key=/library/metadata/11")
      refute_received {:request, "POST", "/playQueues", _params}

      body = poll("7").resp_body

      assert_received {:request, "POST", "/playQueues", params}
      assert params["uri"] =~ "library/metadata/"
      assert body =~ ~s(playQueueID="26058")
    end

    # **A device that came back from a restart holds a track and no queue.** The queue of
    # this device lives in memory, so it goes when the power does, and the player
    # restores the one track that a person left. A board was in that state on
    # 2026-09-15, and a controller that reached it waited for a queue that no list could
    # make.
    test "a device that holds a track and no queue makes a queue of that track" do
      Settings.put!("plex_machine_id", "abc123")
      start_supervised!(PiFi.Plex.Companion.Queue)

      call("/player/playback/playMedia?key=/library/metadata/11")
      Playback.clear_queue!()
      assert Playback.queue!() == []

      body = poll("8").resp_body

      assert_received {:request, "POST", "/playQueues", params}
      assert params["uri"] =~ "library/metadata/11"
      assert body =~ ~s(playQueueID="26058")
    end

    # A person plays a station, or a track that no controller named, and the queue of
    # the controller says nothing about that.
    test "a track that the queue does not hold names no queue" do
      start_supervised!(PiFi.Plex.Companion.Queue)

      call("/player/playback/createPlayQueue?uri=server://abc/library/metadata/9")
      PiFi.Player.stop()

      refute poll("6").resp_body =~ "playQueueID"
    end
  end

  # A controller sends a play queue and not a track, and these read what it sends.
  describe "a command that plays" do
    test "a queue that the server does not answer uses the one track of the command" do
      conn =
        call("/player/playback/playMedia?key=/library/metadata/404&containerKey=/playQueues/1")

      assert conn.status == 200
    end

    test "a command that names neither a queue nor a track answers" do
      assert call("/player/playback/playMedia").status == 200
    end
  end

  describe "the text of a person in the answer" do
    # A person names their device, and a name holds whatever they typed. An attribute
    # of XML holds neither a quotation mark nor an ampersand.
    test "a name that holds an ampersand does not break the XML" do
      was = Identity.name()
      Identity.put_name("Tea & Toast")

      # `put_name("")` is refused, because a device needs a name, so a test that reset
      # it that way left its own name behind for every test after it.
      on_exit(fn -> Identity.put_name(was) end)

      body = call("/resources").resp_body

      assert body =~ "Tea &amp; Toast"
      refute body =~ "Tea & Toast"
    end
  end
end
