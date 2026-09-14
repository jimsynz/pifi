defmodule MyHiFi.Plex.Companion.Router do
  @moduledoc """
  Answers the requests that a Plex controller sends to a player.

  A controller reads `/resources` to learn what this player is, it polls a timeline to
  draw the state of it, and it sends a command for each control that a person presses.
  Each command carries `X-Plex-Target-Client-Identifier`, which names the player, and a
  `commandID` that counts up.

  Every command becomes a call of `MyHiFi.Playback`, so a person who presses pause on
  their telephone and a person who presses pause on the faceplate reach the same code.

  ## Nothing here is a published specification

  Plex documents none of this. Every shape below comes from reading what a controller
  library sends and what another player answers, so **each one is what an
  implementation does and not what the protocol promises**. Two are worth naming,
  because a measurement against a real controller will settle them and I could not:

  - **The path of the timeline.** `python-plexapi` reads `/timeline/poll`, and the
    plugin of another project answers `/player/timeline/poll`. This answers both, which
    costs two lines and removes the question.
  - **Which attributes a controller needs.** The lists below hold what those two
    implementations name. A controller that wants one that is absent may draw nothing
    at all rather than say so.

  ## The navigation commands are absent, and they stay absent

  A controller also sends `/player/navigation/moveUp` and thirteen more of that family.
  They belong to a player with a screen that a person points a remote at, and they say
  nothing to a device whose screen holds its own navigation. A player that named
  `navigation` in its capabilities and then ignored the commands would be worse than
  one that never named it. See `capabilities/0`.
  """

  use Plug.Router

  require Logger

  alias MyHiFi.Playback
  alias MyHiFi.Plex.Server

  plug :match
  plug Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"]
  plug :dispatch

  # `timeline` is what a controller polls, `playback` is what it commands, and the two
  # play queue names say that this player takes a list and moves through it.
  # `navigation` is absent, and the moduledoc says why.
  @capabilities "timeline,playback,playqueues,playqueues-creation"

  # A player of music holds no screen that a controller draws on, and this is the class
  # that other players of music name.
  @device_class "stb"

  # The two numbers that a controller reads to decide what this player understands.
  # Every implementation that I read names these.
  @protocol_version "1"
  @protocol "plex"

  @doc "What this player tells a controller that it can do."
  @spec capabilities() :: String.t()
  def capabilities, do: @capabilities

  get "/resources" do
    send_xml(conn, resources())
  end

  # Both paths, because two implementations disagree about which one a controller uses.
  get "/player/timeline/poll" do
    send_xml(conn, timeline())
  end

  get "/timeline/poll" do
    send_xml(conn, timeline())
  end

  get "/player/playback/play" do
    answer(conn, Playback.pause(false))
  end

  get "/player/playback/pause" do
    answer(conn, Playback.pause(true))
  end

  get "/player/playback/stop" do
    answer(conn, Playback.stop())
  end

  get "/player/playback/skipNext" do
    answer(conn, Playback.next())
  end

  get "/player/playback/skipPrevious" do
    answer(conn, Playback.previous())
  end

  # **A controller names a place in the track, and this firmware moves by a span.** The
  # offset is where a person wants to be, so the span is that less where they are.
  get "/player/playback/seekTo" do
    case whole(conn.params["offset"]) do
      nil -> answer(conn, {:error, :no_offset})
      offset -> answer(conn, Playback.skip(offset - Playback.state!().position_ms))
    end
  end

  # `volume` is the one parameter of this command that a player of music holds. A
  # controller sends `shuffle` and `repeat` here as well, and `MyHiFi.Playback.Queue`
  # holds neither yet.
  get "/player/playback/setParameters" do
    case whole(conn.params["volume"]) do
      nil -> answer(conn, :ok)
      volume -> answer(conn, Playback.set_volume(volume))
    end
  end

  # **`key` names the track of the server, and `source_ref` of an item is that name.**
  # `MyHiFi.Plex.Fill` writes the `ratingKey` of Plex into that column, so the last
  # segment of the key of a controller finds the row with no map of its own.
  get "/player/playback/playMedia" do
    case item_of(conn.params["key"]) do
      {:ok, item} -> answer(conn, Playback.play([item.id]))
      {:error, reason} -> answer(conn, {:error, reason})
    end
  end

  match _ do
    Logger.info("A Plex controller asked for #{conn.method} #{conn.request_path}.")

    send_xml(conn, container([]))
  end

  # A command answers with an empty container, and a controller reads the timeline for
  # the state that follows. A command that failed says so in the log and answers the
  # same, because a controller has nowhere to draw the reason and a person is holding
  # the telephone and not this device.
  defp answer(conn, {:error, reason}) do
    Logger.warning(
      "A Plex controller asked for something that did not happen: #{inspect(reason)}"
    )

    send_xml(conn, container([]))
  end

  defp answer(conn, _result), do: send_xml(conn, container([]))

  defp resources do
    container([
      {"Player",
       [
         {"title", Server.device_name()},
         {"protocol", @protocol},
         {"protocolVersion", @protocol_version},
         {"protocolCapabilities", @capabilities},
         {"machineIdentifier", Server.client_id()},
         {"product", Server.product()},
         {"platform", Server.platform()},
         {"platformVersion", Server.version()},
         {"deviceClass", @device_class}
       ]}
    ])
  end

  # **The timeline is the state of the player in the words of Plex.** A controller draws
  # the whole of what a person sees from it, and it names one element for each kind of
  # media, because a player may hold a film and a song at once. This one holds music.
  defp timeline do
    state = Playback.state!()

    container([
      {"Timeline", music(state)},
      {"Timeline", [{"type", "video"}, {"state", "stopped"}]},
      {"Timeline", [{"type", "photo"}, {"state", "stopped"}]}
    ])
  end

  defp music(state) do
    [
      {"type", "music"},
      {"state", play_state(state)},
      {"time", to_string(state.position_ms)},
      {"machineIdentifier", Server.client_id()},
      {"protocol", @protocol},
      {"controllable", "playPause,stop,skipNext,skipPrevious,seekTo,volume"}
    ] ++ track(state)
  end

  # A device that plays nothing names no track, and a controller then draws the empty
  # state that it draws for a player that a person has not used.
  defp track(%{item: nil}), do: []

  defp track(%{item: item} = state) do
    [
      {"duration", to_string(item.duration_ms || 0)},
      {"key", "/library/metadata/#{item.source_ref}"},
      {"ratingKey", item.source_ref},
      {"volume", to_string(volume())}
    ] ++ server(state)
  end

  # **The controller reads the track from the server and not from this device**, so the
  # timeline names where that server is. A track of another source names none, and a
  # controller then shows the state and no artwork.
  defp server(%{source: MyHiFi.Source.Plex}) do
    case Server.link() do
      {:ok, %{address: address}} ->
        uri = URI.parse(address)

        [
          {"address", uri.host},
          {"port", to_string(uri.port)},
          {"protocol", uri.scheme}
        ]

      {:error, _reason} ->
        []
    end
  end

  defp server(_state), do: []

  defp play_state(%{playing?: true}), do: "playing"
  defp play_state(%{paused?: true}), do: "paused"
  defp play_state(_state), do: "stopped"

  defp volume do
    case Playback.volume!() do
      %{enabled?: true, percent: percent} -> percent
      _other -> 100
    end
  end

  defp item_of(nil), do: {:error, :no_key}

  defp item_of(key) do
    ref = key |> to_string() |> String.split("/") |> List.last()

    case Playback.items_of_source!("plex") |> Enum.find(&(&1.source_ref == ref)) do
      nil -> {:error, {:no_such_track, ref}}
      item -> {:ok, item}
    end
  end

  defp whole(nil), do: nil

  defp whole(text) do
    case Integer.parse(to_string(text)) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp send_xml(conn, body) do
    conn
    |> put_resp_content_type("text/xml")
    |> send_resp(200, body)
  end

  # The answer of every endpoint is a `MediaContainer`, and a command that says nothing
  # answers an empty one.
  defp container(children) do
    ~s(<?xml version="1.0" encoding="UTF-8"?>\n<MediaContainer size="#{length(children)}">) <>
      Enum.map_join(children, "", &element/1) <> "</MediaContainer>"
  end

  defp element({name, attributes}) do
    "<#{name}" <> Enum.map_join(attributes, "", &attribute/1) <> " />"
  end

  defp attribute({name, value}) do
    ~s( #{name}="#{escaped(value)}")
  end

  # A title carries the name that a person gave the device, and a name is text of a
  # person. An attribute of XML holds neither a quotation mark nor an ampersand.
  defp escaped(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
