defmodule MyHiFi.Plex.CompanionTest do
  use MyHiFi.DataCase, async: false

  doctest MyHiFi.Plex.Companion, import: true

  alias MyHiFi.Device.Identity
  alias MyHiFi.Plex.Companion
  alias MyHiFi.Plex.Companion.Router
  alias MyHiFi.Settings

  # **This calls the router and it opens no port.** `Plug.Test` builds the connection,
  # so a test reads the answers of a controller with no listener at all, and a suite
  # that ran on a build agent needs no port of it.
  import Plug.Test
  import Plug.Conn

  setup do
    on_exit(fn ->
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
  # opposite of a source, and `MyHiFi.Plex.Companion` says why.
  describe "whether a person turned the player on" do
    test "a device that no person changed holds the port closed" do
      refute Companion.enabled?()
    end

    test "a person turns it on, and the answer stays" do
      Companion.enable(true)

      assert Companion.enabled?()
      assert {:ok, %{value: "true"}} = Settings.fetch(Companion.enabled_key())
    end

    test "a person turns it off again" do
      Companion.enable(true)
      Companion.enable(false)

      refute Companion.enabled?()
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
      assert Router.capabilities() == "timeline,playback,playqueues,playqueues-creation"
      refute Router.capabilities() =~ "navigation"
    end

    test "the answer is XML" do
      conn = call("/resources")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/xml"
      assert conn.resp_body =~ ~s(<?xml version="1.0" encoding="UTF-8"?>)
    end
  end

  describe "the timeline" do
    # Two implementations disagree about the path, so this answers both.
    test "both paths that a controller may read give the same answer" do
      assert call("/player/timeline/poll").resp_body == call("/timeline/poll").resp_body
    end

    test "a device that plays nothing says that it is stopped" do
      body = call("/timeline/poll").resp_body

      assert attribute(body, "Timeline", "type") == "music"
      assert attribute(body, "Timeline", "state") in ["stopped", "paused"]
    end

    # A controller draws one element for each kind of media, because a player may hold
    # a film and a song at once. This one holds music, and it says so of the others.
    test "it names the three kinds of media" do
      body = call("/timeline/poll").resp_body

      assert body =~ ~s(type="music")
      assert body =~ ~s(type="video")
      assert body =~ ~s(type="photo")
    end

    test "it names the controls that a person may press" do
      body = call("/timeline/poll").resp_body

      assert attribute(body, "Timeline", "controllable") =~ "playPause"
      assert attribute(body, "Timeline", "skipNext") == nil
    end
  end

  describe "a command" do
    test "each one answers an empty container, and a controller reads the timeline" do
      for path <- [
            "/player/playback/pause",
            "/player/playback/stop",
            "/player/playback/skipNext",
            "/player/playback/skipPrevious",
            "/player/playback/setParameters"
          ] do
        conn = call(path)

        assert conn.status == 200
        assert conn.resp_body =~ "MediaContainer"
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

    test "a path that this player does not hold answers an empty container" do
      conn = call("/player/navigation/moveUp")

      assert conn.status == 200
      assert conn.resp_body =~ ~s(size="0")
    end
  end

  describe "the text of a person in the answer" do
    # A person names their device, and a name holds whatever they typed. An attribute
    # of XML holds neither a quotation mark nor an ampersand.
    test "a name that holds an ampersand does not break the XML" do
      Identity.put_name("Tea & Toast")

      on_exit(fn -> Identity.put_name("") end)

      body = call("/resources").resp_body

      assert body =~ "Tea &amp; Toast"
      refute body =~ "Tea & Toast"
    end
  end
end
