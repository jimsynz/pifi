defmodule MyHiFi.Plex.Companion.Router do
  @moduledoc """
  Answers the requests that a Plex controller sends to a player.

  A controller reads `/resources` to learn what this player is, it polls a timeline to
  draw the state of it, and it sends a command for each control that a person presses.
  Each command carries `X-Plex-Target-Client-Identifier`, which names the player, and a
  `commandID` that counts up.

  Every command becomes a call of `MyHiFi.Playback`, so a person who presses pause on
  their telephone and a person who presses pause on the faceplate reach the same code.

  ## Plex documents none of this, so a real player was measured instead

  Every shape below comes from a reading of Plexamp 4.13.2 on 2026-09-15, which is a
  player of this protocol that works. Four answers of that measurement are the reason
  that this module reads as it does, and each one corrected a guess:

  - **The path of the timeline is `/player/timeline/poll`.** The bare `/timeline/poll`
    answers 404 on a real player, so this holds one path and not two.
  - **`commandID` is not optional.** A poll that names none answers `400`, and the
    answer of one that does names that number on the container. A controller counts it
    up and it reads the answers against it.
  - **The `machineIdentifier` of a timeline is the server and not the player.** It sits
    beside the address, the port and the protocol, and the four together tell a
    controller where to ask for the artwork of the track. `/resources` names the player
    in that attribute, and the two are different identifiers. See
    `MyHiFi.Plex.Server.machine_id/0`.
  - **A path that a player does not hold answers 404**, and a command answers 200 with
    no body at all. A player that answered every path would tell a controller that it
    holds a control which does nothing.

  ## What a controller cannot read here yet

  A real player names `playQueueID`, `playQueueItemID`, `playQueueVersion` and
  `containerKey` on its timeline, and this names none of them. The queue of this
  firmware is `MyHiFi.Playback.Queue`, which is a list on the device and not a play
  queue of the server, so there is no number of that kind to give. A controller can
  therefore draw the track that plays and not the list that it came from.

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

  # **A real player answers this path alone**, and it refuses a poll that names no
  # `commandID`. See the moduledoc.
  get "/player/timeline/poll" do
    case conn.params["commandID"] do
      nil -> send_resp(conn, 400, "")
      id -> send_xml(conn, timeline(id))
    end
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

  # **A controller does not send a track, it sends a play queue.** A person who presses
  # an album makes a queue of it on the server, and `containerKey` names that queue. A
  # player that read the one `key` would play one song of the record and stop, and the
  # skip of that person would then do nothing.
  #
  # `key` is the answer for a controller that names no queue, and `source_ref` of an
  # item is the `ratingKey` that both of them carry, so a row is found with no map of
  # its own.
  #
  # **`offset` is not honoured, and a controller may send one.** It names the place to
  # start at, and this firmware has no way to start a song at a place: the position of
  # an item belongs to the items that keep their place, and a song of a library keeps
  # none. A person who moves a controller to the middle of a track and sends it here
  # hears that track from the beginning.
  get "/player/playback/playMedia" do
    answer(conn, played(conn.params["containerKey"], conn.params["key"]))
  end

  # **A path that this player does not hold answers 404**, in the way that a real player
  # does. The line of the log names it, so a controller that wants something absent says
  # so here and not in silence.
  match _ do
    Logger.info("A Plex controller asked for #{conn.method} #{conn.request_path}.")

    send_resp(conn, 404, "")
  end

  # A command answers 200 with no body, and a controller reads the timeline for the
  # state that follows. A command that failed says so in the log and answers the same,
  # because a controller has nowhere to draw the reason and a person is holding the
  # telephone and not this device.
  defp answer(conn, {:error, reason}) do
    Logger.warning(
      "A Plex controller asked for something that did not happen: #{inspect(reason)}"
    )

    send_resp(conn, 200, "")
  end

  defp answer(conn, _result), do: send_resp(conn, 200, "")

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
         # **`version` is the version of the player, and `platformVersion` is the
         # version of what it runs on.** A real player names both: Plexamp 4.13.2 on
         # macOS 25.6.0 names each number in its own place. The firmware is both of
         # those for this device, so the two carry the same number.
         {"version", Server.version()},
         {"deviceClass", @device_class}
       ]}
    ])
  end

  # **The timeline is the state of the player in the words of Plex.** A controller draws
  # the whole of what a person sees from it, and it names one element for each kind of
  # media, because a player may hold a film and a song at once. This one holds music.
  #
  # The container names the `commandID` of the request and no size, which is what a real
  # player answers.
  defp timeline(command_id) do
    state = Playback.state!()

    container(
      [
        {"Timeline", music(state)},
        {"Timeline", [{"type", "video"}, {"state", "stopped"}]},
        {"Timeline", [{"type", "photo"}, {"state", "stopped"}]}
      ],
      [{"commandID", command_id}]
    )
  end

  defp music(state) do
    [
      {"type", "music"},
      {"itemType", "music"},
      {"state", play_state(state)},
      {"time", to_string(state.position_ms)},
      {"shuffle", "0"},
      {"repeat", "0"},
      # A real player names the level whether it plays something or not, so a controller
      # draws the control of it for a device that is quiet.
      {"volume", to_string(volume())},
      {"controllable", Enum.join(controllable(state), ",")}
    ] ++ track(state)
  end

  # **The list answers what a person may press now, and it is not a constant.** A real
  # player drops `skipNext` from it when it holds nothing to play next, and a controller
  # reads the list to decide which of its controls to draw. A list that never changed
  # would give a person a control that does nothing, which is the same fault as claiming
  # a capability that this player does not answer.
  #
  # `shuffle`, `repeat`, `stepBack` and `stepForward` are never in it, because
  # `MyHiFi.Playback` holds none of those.
  defp controllable(%{item: nil}), do: ["volume"]

  defp controllable(state) do
    ["playPause", "stop", "volume"] ++ seeking(state) ++ moving()
  end

  # **A live stream has no place to move to.** A station plays until a person stops it,
  # so a controller must not draw a progress bar that they can press.
  defp seeking(%{live?: true}), do: []
  defp seeking(_state), do: ["seekTo"]

  # The queue decides what next and previous mean, so an empty one holds neither. It
  # lives in memory, so this costs no read of the card. See `MyHiFi.Playback.Queue`.
  defp moving do
    case Playback.queue!() do
      rows when length(rows) > 1 -> ["skipNext", "skipPrevious"]
      _rows -> []
    end
  end

  # A device that plays nothing names no track, and a controller then draws the empty
  # state that it draws for a player that a person has not used.
  defp track(%{item: nil}), do: []

  defp track(%{item: item} = state) do
    [
      {"duration", to_string(item.duration_ms || 0)},
      {"key", "/library/metadata/#{item.source_ref}"},
      {"ratingKey", item.source_ref}
    ] ++ server(state)
  end

  # **The controller reads the track from the server and not from this device**, so the
  # timeline names where that server is: the identifier of the machine, the address, the
  # port and the protocol, and a real player names the four together. A track of another
  # source names none of them, and a controller then shows the state and no artwork.
  defp server(%{source: MyHiFi.Source.Plex}) do
    with {:ok, %{address: address}} <- Server.link(),
         {:ok, machine_id} <- Server.machine_id() do
      uri = URI.parse(address)

      [
        {"machineIdentifier", machine_id},
        {"address", uri.host},
        {"port", to_string(uri.port)},
        {"protocol", uri.scheme}
      ]
    else
      _other -> []
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

  # The queue of the server decides the order and the row, so a person who pressed the
  # ninth track of a record hears the record from there.
  defp played(nil, key), do: one_track(key)

  defp played(container_key, key) do
    case Server.play_queue(container_key) do
      {:ok, %{refs: refs, selected: selected}} -> queued(refs, selected, key)
      {:error, _reason} -> one_track(key)
    end
  end

  # **A queue of the server holds the tracks that this device has read, and no others.**
  # A read of the library writes a row for each track, so a queue of a library that the
  # device knows maps whole. A track that is absent leaves the list, and the place of
  # the person moves with it.
  defp queued(refs, selected, key) do
    items = items_of(refs)
    ids = refs |> Enum.map(&items[&1]) |> Enum.reject(&is_nil/1)

    case ids do
      [] -> one_track(key)
      ids -> Playback.play(ids, %{playing_index: place(refs, items, selected)})
    end
  end

  # The place of the row that a person pressed, counted over the tracks that this
  # device holds. A track that the device does not hold is not in the list, so the
  # place of every row after it moves.
  defp place(refs, items, selected) do
    refs
    |> Enum.take(selected)
    |> Enum.count(&items[&1])
  end

  defp items_of(refs) do
    "plex"
    |> Playback.items_of_source!()
    |> Enum.filter(&(&1.source_ref in refs))
    |> Map.new(&{&1.source_ref, &1.id})
  end

  defp one_track(key) do
    case item_of(key) do
      {:ok, item} -> Playback.play([item.id])
      {:error, reason} -> {:error, reason}
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

  # **A `MediaContainer` names its size or the `commandID` of the request, and not
  # both.** `/resources` answers the first and a timeline answers the second, which is
  # what a real player does. It writes no declaration of XML, for the same reason.
  defp container(children), do: container(children, [{"size", length(children)}])

  defp container(children, attributes) do
    "<MediaContainer" <>
      Enum.map_join(attributes, "", &attribute/1) <>
      ">" <> Enum.map_join(children, "", &element/1) <> "</MediaContainer>"
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
