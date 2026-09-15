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

  require Ash.Query
  require Logger

  alias MyHiFi.Event
  alias MyHiFi.Playback
  alias MyHiFi.Playback.Item
  alias MyHiFi.Plex.Companion.Queue
  alias MyHiFi.Plex.Server
  alias MyHiFi.Source

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

  # How long a poll of `wait=1` holds when the player says nothing. See `state_of/1`.
  @wait :timer.seconds(5)

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
      nil ->
        send_resp(conn, 400, "")

      id ->
        state = state_of(conn.params["wait"])

        send_xml(conn, timeline(id, state, metadata_of(conn.params["includeMetadata"], state)))
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
    answer(conn, playing(conn.params["containerKey"], conn.params["key"]))
  end

  # **A controller does not always name a queue that exists, and it asks the player to
  # make one.** `uri` names a record, an artist or a playlist of the library, and the
  # server resolves it, so this reads no part of that address.
  #
  # **Whether a controller sends `playMedia` after this is not known.** A real player
  # answers 200 with no body for this command, as it does for every other, and a
  # measurement could not see what a controller does next. This player therefore plays
  # what it makes, because a person who pressed a record must hear it. A `playMedia`
  # that followed would name the queue that this made, so it would play the same
  # tracks from the same place.
  get "/player/playback/createPlayQueue" do
    answer(conn, made(conn.params["uri"]))
  end

  # **A path that this player does not hold answers 404**, in the way that a real player
  # does.
  #
  # **A line of the log for each such request fills the log of the device.** A
  # controller asked a board for `/library/metadata/470959` on 2026-09-15 and it asked
  # again when the answer was 404, and 1020 of those lines filled the ring of 1024 and
  # pushed out every error that a person needed to read.
  #
  # A path under `/player` is a control that a controller wanted and this player does
  # not answer, which is worth a line. Any other path is one that a player was never
  # meant to serve, and `/library/metadata` is the server asked of the wrong machine, so
  # that one goes to the level that a device does not keep.
  match _ do
    # **The parameters are the whole of what a control needs to answer**, and a line
    # that named the path alone said which control a controller wanted and nothing about
    # what it wanted done. `createPlayQueue` was found that way, and then it had to be
    # asked for again to learn what it carries.
    Logger.log(
      level_of(conn.request_path),
      "A Plex controller asked this player for #{conn.method} #{conn.request_path}, " <>
        "which it does not answer. It named #{inspect(Map.drop(conn.params, ["commandID"]))}."
    )

    send_resp(conn, 404, "")
  end

  @doc """
  The level of the log that an unanswered path is worth.

  A path under `/player` is a control that a controller wanted and this player does not
  hold, and a person who reads the log of a device must find it. Any other path is one
  that a player was never meant to serve, and `/library/metadata` is the server asked of
  the wrong machine.

      iex> MyHiFi.Plex.Companion.Router.level_of("/player/playback/stepForward")
      :info

      iex> MyHiFi.Plex.Companion.Router.level_of("/library/metadata/470959")
      :debug

  """
  @spec level_of(String.t()) :: :info | :debug
  def level_of("/player/" <> _rest), do: :info
  def level_of(_path), do: :debug

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
  # **A controller asks this player to hold the poll until something changes.** `wait=1`
  # is what asks, and a player that answered at once turned a controller into a loop:
  # a board on 2026-09-15 answered 25 of these in the few seconds that a probe watched,
  # and each one is a read of the state and a write of the network on a board of four
  # small cores.
  #
  # **It waits for an event of the player, and it gives up before a controller does.**
  # Every change that a controller draws publishes one: the track, the place, the pause
  # and the level. Answering early costs nothing, because the controller asks again, and
  # holding longer than the controller waits would make it drop the answer that it asked
  # for. The measurement that would name the number of a real player could not be taken,
  # so this is the short side of the guess.
  defp state_of("1") do
    :ok = Event.subscribe(:player)

    receive do
      %_{} -> :ok
    after
      @wait -> :ok
    end

    Event.unsubscribe(:player)

    Playback.state!()
  end

  defp state_of(_wait), do: Playback.state!()

  # The container names the `commandID` of the request and no size, which is what a real
  # player answers.
  @doc """
  The timeline of one state of the player, as a controller reads it.

  **It takes the state and it reads none**, so a test may give it a device that plays a
  track of a library and read the XML that a controller would. That matters for one
  fault in particular: an element that names an attribute twice is not XML, and only a
  state that holds a track reaches the attributes of the server. See
  `MyHiFi.Plex.CompanionTest`.
  """
  @spec timeline(String.t(), map(), String.t() | nil) :: String.t()
  def timeline(command_id, state, metadata \\ nil) do
    container(
      [
        {"Timeline", music(state), metadata},
        {"Timeline", [{"type", "video"}, {"state", "stopped"}]},
        {"Timeline", [{"type", "photo"}, {"state", "stopped"}]}
      ],
      [{"commandID", command_id}]
    )
  end

  # **A controller asks the player to put the metadata of the track in the timeline**,
  # and it draws the title, the record, the artist and the artwork from it. A timeline
  # with none gave Plexamp nothing to draw, and it showed an empty screen and a spinner.
  #
  # The element comes from the server, and this firmware writes no part of that shape.
  # A track of another source names none: only a Plex server holds the metadata that a
  # Plex controller reads.
  defp metadata_of("1", %{item: %{source_ref: ref}, source: MyHiFi.Source.Plex})
       when is_binary(ref) do
    case Server.metadata(ref) do
      {:ok, xml} -> xml
      {:error, _reason} -> nil
    end
  end

  defp metadata_of(_include, _state), do: nil

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
    ] ++ queue_named(item.source_ref) ++ server(state)
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

  # **A track that no controller asked for still needs a queue.** A person plays a
  # record from the page of the device, or the device comes back from a restart with the
  # track that it held, and then a controller reaches it. That controller draws its
  # screen from a play queue, so a track with none leaves it waiting: a person cast to
  # this device on 2026-09-15 and watched a spinner for a track that was sitting there
  # paused.
  #
  # **The queue is made when a controller asks and not before.** A device that plays to
  # a room with no controller in it needs no queue of the server, and a request of that
  # server for every track that a person played would be a cost for nothing.
  defp queue_named(ref) do
    case Queue.of(ref) do
      [] -> Queue.of(made_for(ref))
      named -> named
    end
  end

  # The tracks that this device holds in its own queue, in the order that it plays them,
  # so a controller reads the list that a person made and not the one track that plays.
  #
  # **A device that came back from a restart holds a track and no queue.**
  # `MyHiFi.Playback.Queue` lives in memory, so it goes when the power does, and
  # `MyHiFi.Player` restores the one track that a person left. The queue of that device
  # is that track, and a queue of one is the truth for it.
  defp made_for(ref) do
    with {:ok, uri} <- Server.play_queue_uri(with_playing(plex_refs(), ref)),
         {:ok, queue} <- Server.create_play_queue(uri) do
      Queue.keep(queue)
    end

    ref
  end

  # **A queue that holds no row for the track that plays is no use at all**, because the
  # row of that track is what the timeline names. The track goes first when the queue of
  # the device does not hold it.
  defp with_playing(refs, ref) do
    if ref in refs, do: refs, else: [ref | refs]
  end

  defp plex_refs do
    ids = Playback.queue!() |> Enum.sort_by(& &1.position) |> Enum.map(& &1.item_id)

    Item
    |> Ash.Query.filter(source == "plex" and id in ^ids)
    |> Ash.Query.select([:id, :source_ref])
    |> Ash.read!()
    |> Map.new(&{&1.id, &1.source_ref})
    |> then(fn refs -> ids |> Enum.map(&refs[&1]) |> Enum.reject(&is_nil/1) end)
  end

  defp play_state(%{playing?: true}), do: "playing"
  defp play_state(%{paused?: true}), do: "paused"

  # **A track that holds the player and makes no sound yet is buffering, and it is not
  # stopped.** The player reads the service of the source and builds a pipeline before
  # the first sound, and a Plex track that the server converts takes seconds over it. A
  # controller that read `stopped` there took it for the end of the music and told the
  # player to stop: a person heard the first track of a playlist and then silence.
  defp play_state(%{item: item}) when not is_nil(item), do: "buffering"
  defp play_state(_state), do: "stopped"

  defp volume do
    case Playback.volume!() do
      %{enabled?: true, percent: percent} -> percent
      _other -> 100
    end
  end

  # **A device that a controller drives leaves standby and it takes the switch with
  # it.** The player wakes by itself, because a play is a play whoever asked for it. The
  # switch does not: `MyHiFi.Source.choose/1` is what the pages of a person call when
  # they move to a source, and a controller moves no page. A person who hears their
  # record and then walks to the device must find it where the music is.
  #
  # **It goes here and not in `MyHiFi.Player`.** A play of that module is every play,
  # and a track of the queue that follows the one a person chose would move the switch
  # under them. A controller is the caller that has no page of its own.
  defp playing(container_key, key) do
    case played(container_key, key) do
      {:ok, _result} = played ->
        Source.choose(MyHiFi.Source.Plex)

        played

      other ->
        other
    end
  end

  defp made(nil), do: {:error, :no_uri}

  defp made(uri) do
    with {:ok, queue} <- Server.create_play_queue(uri),
         {:ok, _result} = played <- from_queue(queue) do
      Source.choose(MyHiFi.Source.Plex)

      played
    end
  end

  # The queue of the server decides the order and the row, so a person who pressed the
  # ninth track of a record hears the record from there.
  defp played(nil, key), do: one_track(key)

  defp played(container_key, key) do
    case Server.play_queue(container_key) do
      {:ok, queue} -> queued(queue, key)
      {:error, _reason} -> one_track(key)
    end
  end

  # **A queue of the server holds the tracks that this device has read, and no others.**
  # A read of the library writes a row for each track, so a queue of a library that the
  # device knows maps whole. A track that is absent leaves the list, and the place of
  # the person moves with it.
  defp queued(queue, key) do
    case from_queue(queue) do
      {:error, {:no_track_of_that_queue, _count}} -> one_track(key)
      answer -> answer
    end
  end

  # **A queue of the server holds the tracks that the server holds, and this device
  # holds the ones that it has read.** A queue that maps to none of them plays nothing,
  # and the count says how many the controller named, because a person whose library
  # the device has not finished reading meets that and no other fault.
  defp from_queue(%{refs: refs, selected: selected} = queue) do
    items = items_of(refs)
    ids = refs |> Enum.map(&items[&1]) |> Enum.reject(&is_nil/1)

    case ids do
      [] ->
        {:error, {:no_track_of_that_queue, length(refs)}}

      ids ->
        # **The controller reads its screen from the queue**, so the player holds the one
        # that it was given. See `MyHiFi.Plex.Companion.Queue`.
        Queue.keep(queue)

        Playback.play(ids, %{playing_index: place(refs, items, selected)})
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

  # **The database does the matching, and this reads no row that it did not ask for.**
  # A queue of a controller names a handful of tracks and a library holds tens of
  # thousands, so a read of the source and a filter in memory made a board give up: a
  # controller asked for one record, the read took 63,010 rows of a table of 137,575,
  # and the connection of the database stopped after 15 seconds with `interrupted`.
  #
  # `(source, source_ref)` is a unique index of this table, so each batch below is an
  # indexed read. **The batch is 500, because each reference is a value of one
  # statement**, and SQLite takes a limited number of them.
  defp items_of(refs) do
    refs
    |> Enum.chunk_every(500)
    |> Enum.reduce(%{}, fn batch, held -> Map.merge(held, items_of_batch(batch)) end)
  end

  defp items_of_batch(refs) do
    Item
    |> Ash.Query.filter(source == "plex" and source_ref in ^refs)
    |> Ash.Query.select([:id, :source_ref])
    |> Ash.read!()
    |> Map.new(&{&1.source_ref, &1.id})
  end

  defp one_track(key) do
    case item_of(key) do
      {:ok, id} -> Playback.play([id])
      {:error, reason} -> {:error, reason}
    end
  end

  defp item_of(nil), do: {:error, :no_key}

  # One row of the unique index, and not a read of the whole source. See `items_of/1`.
  defp item_of(key) do
    ref = key |> to_string() |> String.split("/") |> List.last()

    case items_of_batch([ref]) do
      %{^ref => id} -> {:ok, id}
      _none -> {:error, {:no_such_track, ref}}
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

  defp element({name, attributes}), do: element({name, attributes, nil})

  defp element({name, attributes, nil}) do
    "<#{name}" <> Enum.map_join(attributes, "", &attribute/1) <> " />"
  end

  # **An element that holds another one cannot close itself.** The metadata of a track
  # sits inside the timeline of the player, and a real player writes it that way.
  defp element({name, attributes, inside}) do
    "<#{name}" <> Enum.map_join(attributes, "", &attribute/1) <> ">" <> inside <> "</#{name}>"
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
