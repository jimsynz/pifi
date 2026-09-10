defmodule MyHiFi.Player do
  @moduledoc """
  Plays one track at a time.

  A caller gives one `MyHiFi.Playback.Item`, and the player asks the source of it to
  resolve it, builds a pipeline, and plays it. It runs one pipeline at a time, and it
  stops the old one first.

  `MyHiFi.Playback.play/2` is what a page calls. It puts the list that a person saw in
  `MyHiFi.Playback.Queue` and then calls this with the row that they pressed.

  It tells the rest of the firmware what it does on the `:player` topic. See
  `MyHiFi.Event.Player`. Nothing reads the state of this process directly, apart
  from `state/0` for a person at the console.

  ## The controls

  A pause stops the pipeline and it keeps the track selected, so a play starts the
  pipeline again at the place that the item reports. A pause therefore needs no mechanism
  of its own.

  A skip keeps the pipeline. It moves the byte that `MyHiFi.Player.FileSource` reads,
  because a pipeline owns the decoder and the buffer of a stream, and a start of one
  reads the network again. `MyHiFi.Output.APlayPort` keeps the sound card across a
  pipeline now, so a start no longer opens the card unless the format of the audio
  changed. See `MyHiFi.Player.Skip`.

  Next and previous move the mark of `MyHiFi.Playback.Queue`, which decides the order
  that a person saw. A track that reaches its end moves the mark as well, and the row
  stays, so a person can go back to what they heard.

  A live stream ends when the network fails, and a person expects the music to
  come back. The player therefore starts the stream again after a short wait, and
  it stops after a few tries.
  """

  use GenServer

  require Logger

  alias MyHiFi.Artwork
  alias MyHiFi.Event
  alias MyHiFi.Event.Player, as: Events
  alias MyHiFi.Output
  alias MyHiFi.Playback
  alias MyHiFi.Player.Download
  alias MyHiFi.Player.Pipeline
  alias MyHiFi.Player.Prefetch
  alias MyHiFi.Settings
  alias MyHiFi.Source

  @progress_interval :timer.seconds(1)
  @restart_delay :timer.seconds(2)
  @terminate_timeout :timer.seconds(5)

  # A person hears silence inside this, or the pipeline is wedged and the forced
  # terminate takes it. A stop of an HLS stream took 360 ms on 2026-08-24.
  @silence_timeout :timer.seconds(1)
  @max_restarts 5

  # A skip answers before the source reads the disk, so a pipeline that does not answer
  # this is a pipeline that is already wedged.
  @skip_timeout :timer.seconds(5)
  @output_device_key "output_device"
  @last_item_key "last_item"
  @standby_key "standby"

  # How long before the end of a track the device reads the next one. A track of 8 MB
  # over slow Wi-Fi takes about this long, and a person who skips in the last half
  # minute of a track costs the card one file that no person hears.
  @prefetch_lead_ms :timer.seconds(30)

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            source: module() | nil,
            item: MyHiFi.Playback.Item.t() | nil,
            playable: map() | nil,
            pipeline: pid() | nil,
            monitor: reference() | nil,
            stream_title: String.t() | nil,
            artwork_path: String.t() | nil,
            started_at: integer() | nil,
            offset_ms: non_neg_integer(),
            position_bytes: non_neg_integer() | nil,
            restarts: non_neg_integer(),
            restart_timer: reference() | nil,
            paused?: boolean(),
            standby?: boolean(),
            prefetched?: boolean()
          }

    defstruct source: nil,
              item: nil,
              playable: nil,
              pipeline: nil,
              monitor: nil,
              stream_title: nil,
              artwork_path: nil,
              started_at: nil,
              offset_ms: 0,
              position_bytes: nil,
              restarts: 0,
              restart_timer: nil,
              paused?: false,
              standby?: false,
              prefetched?: false
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @doc """
  Play one item of the catalogue.

  `MyHiFi.Playback.play/2` puts the list in the queue and calls this with the row that
  a person pressed. See `MyHiFi.Playback.Queue`.

  **This leaves standby**, as `pause/1` and `next/0` do, because a person who asks for
  music asks the device to be awake. A device that played on with the state still in
  standby made sound behind a screen that was dark, and the automatic standby then read
  a device that plays and never went quiet.
  """
  @spec play(MyHiFi.Playback.Item.t()) :: :ok | {:error, term()}
  def play(item), do: GenServer.call(__MODULE__, {:play, item}, :timer.seconds(30))

  @doc "Stop the music."
  @spec stop() :: :ok
  def stop, do: GenServer.call(__MODULE__, :stop)

  @doc """
  Stop the audio and keep the track, or start it again.

  A pause is not a stop. A stop leaves the device with nothing selected, and a pause
  leaves the track in front of the person.

  A play starts the track at the place that the source reports, so a podcast episode
  continues and a live station opens again at the current point of the stream. A play
  also leaves standby, because a person who asks for music asks the device to be
  awake.
  """
  @spec pause(boolean()) :: :ok | {:error, term()}
  def pause(paused?), do: GenServer.call(__MODULE__, {:pause, paused?}, :timer.seconds(30))

  @doc """
  Play the row after the one that plays now.

  The queue decides the order. See `MyHiFi.Playback.Queue`.
  """
  @spec next() :: :ok | {:error, term()}
  def next, do: GenServer.call(__MODULE__, {:move, :next}, :timer.seconds(30))

  @doc """
  Play the row before the one that plays now.

  A track that reached its end stays in the queue, so a person can go back to it.
  """
  @spec previous() :: :ok | {:error, term()}
  def previous, do: GenServer.call(__MODULE__, {:move, :previous}, :timer.seconds(30))

  @doc """
  Move inside the track that plays.

  `ms` is signed, so a backward skip is a negative number. The pipeline keeps playing,
  and the source reports the time that it really moved, which arrives as a
  `MyHiFi.Event.Player.Progress` event.

  A track that a person cannot move inside gives `{:error, :cannot_skip}`: a live
  stream has no place, a source may offer no skip at all, and
  `MyHiFi.Player.Skip` reads MP3 frames alone. A track that makes no sound yet gives
  `{:error, :not_playing}`, and a pause therefore takes no skip.
  """
  @spec skip(integer()) :: :ok | {:error, term()}
  def skip(ms), do: GenServer.call(__MODULE__, {:skip, ms})

  @doc """
  Enter standby, or leave it.

  In standby the device plays nothing and keeps the network. On leaving standby it
  plays the track that it played before.
  """
  @spec standby(boolean()) :: :ok | {:error, term()}
  def standby(entered?), do: GenServer.call(__MODULE__, {:standby, entered?}, :timer.seconds(30))

  @doc """
  What the player is doing, for a person at the console.

  A caller that must not wait passes a timeout and catches the exit.
  `MyHiFi.Playback.Player.state/0` does that, and every page reads it through there.
  """
  @spec state(timeout()) :: map()
  def state(timeout \\ 5000), do: GenServer.call(__MODULE__, :state, timeout)

  @doc """
  The output devices, and the one that the player uses.

  The settings page shows this, so that page needs no knowledge of which output
  module the player uses.

  `selected` is the card that a person chose, and it is nil for a device that no
  person has changed. `in_use` is the card that the sound comes out of, and it is
  nil only when the machine has no card at all. The two are different when a
  person chose nothing, and when the card that they chose has left the machine. A
  page must mark `in_use`, because that is the one that plays.
  """
  @spec output() :: %{
          devices: [map()],
          selected: String.t() | nil,
          in_use: String.t() | nil
        }
  def output, do: GenServer.call(__MODULE__, :output)

  @doc """
  Choose an output device.

  The choice stays after a restart. The player starts the stream again, so a
  person hears the change at once.
  """
  @spec select_output(String.t()) :: :ok | {:error, term()}
  def select_output(id),
    do: GenServer.call(__MODULE__, {:select_output, id}, :timer.seconds(30))

  @doc """
  Put a source in use, or take it out of use.

  A source out of use leaves each user interface, its background jobs do nothing,
  and a restart does not select it again. The player therefore stops when the
  source that plays goes out of use: a person who takes a source away expects the
  sound of it to go as well.
  """
  @spec enable_source(module(), boolean()) :: :ok
  def enable_source(source, enabled?),
    do: GenServer.call(__MODULE__, {:enable_source, source, enabled?}, :timer.seconds(30))

  @doc """
  The settings key of the chosen output device.
  """
  @spec output_device_key() :: String.t()
  def output_device_key, do: @output_device_key

  @impl GenServer
  def init(_options) do
    {:ok, %State{}, {:continue, :restore}}
  end

  # The settings hold the last station and the standby state, so both survive a
  # restart. The device selects that station and plays nothing: a stereo that
  # starts to play by itself after a power cut is a surprise, and section 9 asks
  # for silence at the first start.
  # A person waits for no pipeline. `handle_call(:stop, …)` answers as soon as the
  # sound stops, and this takes the pipeline down before the process reads another
  # message. A `play` that follows therefore still finds the sound card free, which
  # is the reason that `stop_pipeline/1` waits at all.
  @impl GenServer
  def handle_continue({:terminate, pipeline, monitor}, %State{} = state) do
    stop_pipeline(%State{state | pipeline: pipeline, monitor: monitor})

    {:noreply, %State{cancel_restart(state) | pipeline: nil, monitor: nil, started_at: nil}}
  end

  @impl GenServer
  def handle_continue(:restore, %State{} = state) do
    {:noreply, restore_station(%State{state | standby?: stored_standby?()})}
  end

  # The place of the track that plays now goes to its source first. A person who picks
  # another episode, or the next one, must find this one where they left it.
  @impl GenServer
  def handle_call({:play, item}, _from, %State{} = state) do
    case Source.from_slug(item.source) do
      {:ok, source} ->
        if Source.enabled?(source) do
          # `waking/1` goes here and not at the head of the clause, so a play that
          # cannot happen leaves the device as quiet as it found it.
          play_now(source, item, waking(state))
        else
          {:reply, {:error, :source_not_in_use}, state}
        end

      {:error, _reason} ->
        {:reply, {:error, :no_such_source}, state}
    end
  end

  @impl GenServer
  def handle_call(:stop, _from, %State{} = state) do
    {:reply, :ok, cleared(state), {:continue, {:terminate, state.pipeline, state.monitor}}}
  end

  # A pause keeps a track for a person, so a device with nothing selected has nothing
  # to pause.
  @impl GenServer
  def handle_call({:pause, true}, _from, %State{item: nil} = state) do
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:pause, true}, _from, %State{pipeline: nil} = state) do
    {:reply, :ok, %State{state | paused?: true}}
  end

  # `offset_ms` keeps the place, because the terminate below clears `started_at` and
  # `position_ms/1` then counts from the offset alone. A page that opens while the
  # device is paused therefore reads the place that a person stopped at.
  @impl GenServer
  def handle_call({:pause, true}, _from, %State{} = state) do
    store_position(state)
    silence(state)
    Event.publish(:player, %Events.Paused{position_ms: position_ms(state)})

    {:reply, :ok, %State{state | paused?: true, stream_title: nil, offset_ms: position_ms(state)},
     {:continue, {:terminate, state.pipeline, state.monitor}}}
  end

  @impl GenServer
  def handle_call({:pause, false}, _from, %State{item: nil} = state) do
    {:reply, {:error, :nothing_selected}, %State{state | paused?: false}}
  end

  @impl GenServer
  def handle_call({:pause, false}, _from, %State{pipeline: pipeline} = state)
      when pipeline != nil do
    {:reply, :ok, %State{state | paused?: false}}
  end

  @impl GenServer
  def handle_call({:pause, false}, _from, %State{} = state) do
    state = waking(state)

    case start(state.source, state.item, state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  # A move is a play of another row of the queue, so this gives the work to the clause
  # that plays one. That clause writes the place of this track, it stops the pipeline,
  # it keeps the new track in the settings, and it leaves standby. This called
  # `waking/1` of its own before that clause did, and two calls woke a device that then
  # found the source out of use and played nothing.
  @impl GenServer
  def handle_call({:move, direction}, from, %State{} = state) do
    case moved(direction) do
      {:ok, item} -> handle_call({:play, item}, from, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:skip, _ms}, _from, %State{started_at: nil} = state) do
    {:reply, {:error, :not_playing}, state}
  end

  @impl GenServer
  def handle_call({:skip, ms}, _from, %State{} = state) do
    if skippable?(state) do
      {:reply, ask_skip(state, ms), state}
    else
      {:reply, {:error, :cannot_skip}, state}
    end
  end

  @impl GenServer
  def handle_call({:standby, true}, _from, %State{} = state) do
    store_position(state)
    silence(state)
    Settings.put(@standby_key, "true")
    Event.publish(:player, %Events.Standby{entered?: true})

    {:reply, :ok, %State{state | standby?: true, stream_title: nil},
     {:continue, {:terminate, state.pipeline, state.monitor}}}
  end

  @impl GenServer
  def handle_call({:standby, false}, _from, %State{source: nil} = state) do
    {:reply, :ok, waking(state)}
  end

  # A person who paused a track and then pressed standby did not ask for music, so
  # leaving standby leaves that track paused. A play starts it.
  @impl GenServer
  def handle_call({:standby, false}, _from, %State{paused?: true} = state) do
    {:reply, :ok, waking(state)}
  end

  @impl GenServer
  def handle_call({:standby, false}, _from, %State{} = state) do
    state = waking(state)

    case start(state.source, state.item, state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call(:state, _from, %State{} = state) do
    {:reply,
     %{
       source: state.source,
       item: state.item,
       stream_title: state.stream_title,
       artwork_path: state.artwork_path,
       playing?: state.started_at != nil,
       paused?: state.paused?,
       standby?: state.standby?,
       position_ms: position_ms(state),
       live?: live?(state)
     }, state}
  end

  @impl GenServer
  def handle_call(:output, _from, %State{} = state) do
    devices = Output.module().devices()
    chosen = chosen_device()

    in_use =
      case device_in_use(devices, chosen) do
        %{id: id} -> id
        nil -> nil
      end

    {:reply, %{devices: devices, selected: chosen, in_use: in_use}, state}
  end

  # A person who takes a source away expects the sound of it to go as well, and they
  # expect the device not to select it again after a restart.
  @impl GenServer
  def handle_call({:enable_source, source, enabled?}, _from, %State{} = state) do
    Source.enable(source, enabled?)

    if enabled? or state.source != source do
      {:reply, :ok, state}
    else
      {:reply, :ok, state |> cleared() |> forget_station(),
       {:continue, {:terminate, state.pipeline, state.monitor}}}
    end
  end

  @impl GenServer
  def handle_call({:select_output, id}, _from, %State{} = state) do
    case Settings.put(@output_device_key, id) do
      {:ok, _setting} -> {:reply, :ok, restart_for_output(state)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info(:progress, %State{pipeline: nil} = state), do: {:noreply, state}

  @impl GenServer
  def handle_info(:progress, %State{started_at: nil} = state), do: {:noreply, state}

  @impl GenServer
  def handle_info(:progress, %State{} = state) do
    Event.publish(:player, %Events.Progress{
      position_ms: position_ms(state),
      duration_ms: state.item && state.item.duration_ms
    })

    schedule_progress()
    {:noreply, prefetch(state)}
  end

  @impl GenServer
  def handle_info({:pipeline_playing, pipeline}, %State{pipeline: pipeline} = state) do
    artwork_path = artwork_path(state.item)

    Event.publish(:player, %Events.Started{
      source: state.source,
      track: state.item,
      artwork_path: artwork_path,
      live?: live?(state),
      position_ms: position_ms(state)
    })

    schedule_progress()

    # The count of tries resets here and not where the pipeline starts. Building a
    # pipeline proves nothing: a stream that never arrives builds one each time,
    # and the player would then try for ever. Sound is the proof.
    {:noreply,
     %State{
       state
       | started_at: System.monotonic_time(:millisecond),
         restarts: 0,
         artwork_path: artwork_path
     }}
  end

  # `MyHiFi.Player.FileSource` reports the byte that it has read. The player keeps
  # the last one, and `store_position/1` writes it beside the time. The two numbers
  # therefore come from one stop, and no part of this firmware turns a time into a
  # byte with a bitrate. See `MyHiFi.Source.place/0`.
  @impl GenServer
  def handle_info({:pipeline_position_bytes, pipeline, bytes}, %State{pipeline: pipeline} = state) do
    {:noreply, %State{state | position_bytes: bytes}}
  end

  # The element measured the time that it moved, so the count of the player follows it
  # and no part of this firmware turns a byte into a time. The progress event goes out
  # here and not one second later, because a person who presses a skip watches the
  # count.
  @impl GenServer
  def handle_info({:pipeline_skipped, pipeline, place}, %State{pipeline: pipeline} = state) do
    state = %State{
      state
      | offset_ms: state.offset_ms + place.ms,
        position_bytes: place.byte
    }

    Event.publish(:player, %Events.Progress{
      position_ms: position_ms(state),
      duration_ms: state.item && state.item.duration_ms
    })

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:pipeline_metadata, pipeline, title}, %State{pipeline: pipeline} = state) do
    # The title stays here as well, because a page that opens in the middle of a
    # track needs it. The next block comes about one second later, and a person
    # should not wait for it.
    Event.publish(:player, %Events.MetadataChanged{title: title})
    {:noreply, %State{state | stream_title: title}}
  end

  @impl GenServer
  def handle_info({:pipeline_finished, pipeline}, %State{pipeline: pipeline} = state) do
    if live?(state) do
      Logger.info("The stream ended. Starting it again.")
      {:noreply, restart(state)}
    else
      Logger.info("The track ended.")
      {:noreply, finish(state)}
    end
  end

  @impl GenServer
  def handle_info(
        {:DOWN, monitor, :process, pipeline, reason},
        %State{pipeline: pipeline, monitor: monitor} = state
      ) do
    Logger.warning("The pipeline stopped: #{inspect(reason)}")
    {:noreply, restart(%State{state | pipeline: nil, monitor: nil})}
  end

  # **A restart belongs to the stream that failed, and to nothing else.** A pipeline
  # that runs now is one that a person asked for after the fault, and a start here
  # would leave it playing with nothing holding it. A player that a person paused must
  # stay quiet as well. `cancel_restart/1` takes the message out of the mailbox, and
  # these two clauses hold the cases that reach the process another way.
  @impl GenServer
  def handle_info(:restart, %State{pipeline: pipeline} = state) when pipeline != nil,
    do: {:noreply, state}

  @impl GenServer
  def handle_info(:restart, %State{paused?: true} = state), do: {:noreply, state}

  @impl GenServer
  def handle_info(:restart, %State{source: source, item: item} = state)
      when source != nil and item != nil do
    case start(source, item, state) do
      {:ok, state} -> {:noreply, state}
      {:error, _reason, state} -> {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(message, state) do
    Logger.debug("Player ignoring #{inspect(message)}")
    {:noreply, state}
  end

  # **Every start ends the pipeline that the state names.** `Membrane.Pipeline.start/2`
  # links nothing to this process, so a state that loses the reference leaves a
  # pipeline that owns `aplay` and keeps the room loud. The next pipeline then finds
  # the sound card busy and dies with `:epipe`, the notices of the one that plays reach
  # a player that does not know it, and a person who presses stop stops nothing. This
  # is the one place that answers for it, so no caller can forget.
  defp start(source, item, %State{} = state) do
    state = state |> cancel_restart() |> stop_pipeline()

    with {:ok, playable} <- source.resolve(item),
         {:ok, sink} <- sink(state) do
      Event.publish(:player, %Events.Buffering{percent: 0})

      case start_pipeline(playable, sink, state) do
        {:ok, pipeline} ->
          monitor = Process.monitor(pipeline)

          # `Started` waits for the source to say that sound began. See
          # `handle_info({:pipeline_playing, _}, _)`. A stream that never arrives
          # therefore never claims to play, and a screen shows the buffering state
          # until there is something to hear.
          {:ok,
           %State{
             state
             | source: source,
               item: item,
               playable: playable,
               pipeline: pipeline,
               monitor: monitor,
               stream_title: nil,
               artwork_path: nil,
               started_at: nil,
               offset_ms: playable.position_ms,
               position_bytes: playable[:position_bytes],
               paused?: false,
               prefetched?: false
           }}

        {:error, reason} ->
          fail(reason, state)
      end
    else
      {:error, reason} -> fail(reason, state)
    end
  end

  # `start/2` and not `start_link/2`. A link would tie the life of this process to
  # the pipeline, and a lost connection would then kill the player instead of
  # letting it start the stream again. The monitor below gives the notice that
  # this process needs, and it survives the pipeline.
  # A test names its own pipeline with `config :my_hi_fi, :pipeline, ...`, in the
  # same way that it names its own source and its own output. The pipeline of this
  # firmware runs `aplay`, and `aplay` opens a sound card, so a test of what the
  # player does at the end of a track cannot use it: the host of a build server
  # has no card. Nothing sets this in production.
  defp start_pipeline(playable, sink, _state) do
    module = Application.get_env(:my_hi_fi, :pipeline, Pipeline)

    case Membrane.Pipeline.start(module, %{
           # The whole playable goes through. A copy of each field here would need
           # a change in two places for each new field, and the first one that
           # nobody changed reached the board.
           playable: playable,
           buffer_bytes: 64 * 1024,
           sink: sink,
           parent: self()
         }) do
      {:ok, _supervisor, pipeline} -> {:ok, pipeline}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sink(%State{}) do
    output = Output.module()

    case device_in_use(output.devices()) do
      %{id: id} -> {:ok, output.sink_spec(id)}
      nil -> {:error, :no_output_device}
    end
  end

  # A person chooses a device, and that choice stays in the settings. A DAC can
  # leave the device, so a choice that names an absent card gives way to the first
  # card that is present. Silence is worse than the wrong socket.
  #
  # `sink/1` and the report of `output/0` both read this, because a settings page
  # must mark the card that the sound comes out of, and the rule is here and not
  # there.
  defp device_in_use(devices), do: device_in_use(devices, chosen_device())

  # The choice comes in, because `Enum.find/3` runs the test for each card and a read
  # of the settings is a query. A board with five cards made six of the same query.
  defp device_in_use(devices, chosen) do
    Enum.find(devices, List.first(devices), &(&1.id == chosen))
  end

  # A page shows the local copy of a logo, and never the address of the station.
  # The content security policy of the device names `'self'` alone. A logo that the
  # cache does not hold arrives in a later event, from `MyHiFi.Artwork.Worker`.
  defp artwork_path(%{artwork: url}) do
    case Artwork.name(url) do
      nil ->
        # The player asks for the logo of the track that it starts, so this job tells
        # the `:player` topic when the picture arrives. See `MyHiFi.Artwork.Worker`.
        Artwork.Worker.enqueue(url, true)
        nil

      name ->
        "/artwork/#{name}"
    end
  end

  defp artwork_path(_track), do: nil

  defp live?(%State{playable: %{live?: live?}}), do: live?
  defp live?(%State{}), do: false

  # A person asked for music, so the device is awake. A stereo that a person presses
  # play on leaves standby, and this device does the same.
  defp waking(%State{standby?: false} = state), do: state

  defp waking(%State{} = state) do
    Settings.put(@standby_key, "false")
    Event.publish(:player, %Events.Standby{entered?: false})
    %State{state | standby?: false}
  end

  # A skip needs four things: a source that offers one, a track with an end, a file to
  # read, and a format that `MyHiFi.Player.Skip` reads. `:download` is the transport
  # that gives the file, and `MyHiFi.Player.FileSource` is the element that moves. All
  # four give one answer to a person: this track takes no skip.
  defp skippable?(%State{
         source: source,
         playable: %{live?: false, transport: :download, format: :mp3}
       }) do
    :skip in source.capabilities()
  end

  defp skippable?(%State{}), do: false

  defp ask_skip(%State{pipeline: pipeline}, ms) do
    Membrane.Pipeline.call(pipeline, {:skip, ms}, @skip_timeout)
    :ok
  catch
    :exit, _reason ->
      Logger.warning("The pipeline did not answer a skip.")
      {:error, :not_playing}
  end

  defp chosen_device do
    case Settings.fetch(@output_device_key) do
      {:ok, %{value: value}} -> value
      {:error, _reason} -> nil
    end
  end

  defp play_now(source, item, %State{} = state) do
    store_position(state)
    release_file(state)

    case start(source, item, state) do
      {:ok, state} ->
        # Only a new choice goes to the settings. Leaving standby and starting the
        # stream again both use the choice that is already there.
        Settings.put(@last_item_key, item.id)
        {:reply, :ok, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  # The queue decides the order, so the row after this one is the row that plays next.
  # An empty queue, and either end of it, both mean the same thing to a person: there
  # is nothing that way. The code interface of Ash wraps the reason, and no caller
  # reads inside it.
  defp moved(direction) do
    case Playback.move_queue(direction) do
      {:ok, row} -> item(row.item_id)
      {:error, _reason} -> {:error, :no_more}
    end
  end

  defp item(id), do: Playback.get_item(id, load: [:artwork])

  # A restored track is a paused track. A person then reads the name of the station
  # and a play control: the device selects the station and plays nothing. A stereo
  # that starts to play by itself after a power cut is a surprise.
  #
  # The queue is in ETS and a restart empties it, so the device comes back with one
  # track selected and no list behind it.
  defp restore_station(%State{} = state) do
    with {:ok, id} <- stored_value(@last_item_key),
         {:ok, item} <- item(id),
         {:ok, source} <- Source.from_slug(item.source),
         true <- Source.enabled?(source) do
      %State{state | source: source, item: item, paused?: true}
    else
      _other -> state
    end
  end

  # A source out of use must not come back after a restart, and the item that it
  # played is no longer of use to any part.
  defp forget_station(%State{} = state) do
    case Settings.fetch(@last_item_key) do
      {:ok, setting} -> Settings.delete(setting)
      {:error, _reason} -> :ok
    end

    state
  end

  @doc """
  Whether the device was in standby when it last wrote that state.

  **This reads the settings and not the process**, so it answers while the player is
  busy and it answers before the player has started. `MyHiFi.Playback.Player.idle/0`
  is the caller, and it says why.

  The player writes this each time that it enters standby and each time that it
  leaves, so the two never disagree for longer than one write.
  """
  @spec stored_standby?() :: boolean()
  def stored_standby?, do: stored_value(@standby_key) == {:ok, "true"}

  defp stored_value(key) do
    case Settings.fetch(key) do
      {:ok, %{value: value}} -> {:ok, value}
      {:error, _reason} -> :error
    end
  end

  defp restart_for_output(%State{source: nil} = state), do: state

  defp restart_for_output(%State{pipeline: nil} = state), do: state

  defp restart_for_output(%State{} = state) do
    store_position(state)

    case start(state.source, state.item, state) do
      {:ok, state} -> state
      {:error, _reason, state} -> state
    end
  end

  # `aplay` owns the sound card, so closing its port is what makes the room quiet.
  # The pipeline may take its time after that. A call that no pipeline answers is a
  # pipeline that is already wedged, and the forced terminate of `stop_pipeline/1`
  # covers that case.
  # A stop leaves the device with nothing selected. The pipeline goes down in a
  # `handle_continue`, so each caller of this adds that step itself.
  defp cleared(%State{} = state) do
    store_position(state)
    release_file(state)
    silence(state)
    Event.publish(:player, %Events.Stopped{reason: :requested})

    %State{
      state
      | source: nil,
        item: nil,
        playable: nil,
        stream_title: nil,
        artwork_path: nil,
        offset_ms: 0,
        position_bytes: nil,
        paused?: false
    }
  end

  defp silence(%State{pipeline: nil}), do: :ok

  defp silence(%State{pipeline: pipeline}) do
    Membrane.Pipeline.call(pipeline, :silence, @silence_timeout)
    :ok
  catch
    :exit, _reason ->
      Logger.warning("The pipeline did not answer a silence.")
      :ok
  end

  defp stop_pipeline(%State{pipeline: nil} = state), do: state

  # **This waits for the old pipeline, and the wait is what makes a change of track
  # work.** `MyHiFi.Output.APlayPort` keeps one port, and two sinks that write to it at
  # once interleave their samples into noise. The order here is what stops that: the old
  # pipeline is gone before `advance/1` builds the next one.
  #
  # The wait began as the answer to another fault, and that one is gone. Each pipeline
  # opened `aplay` of its own then, so a pipeline that started while the old one still
  # ran found the card busy, its `aplay` stopped at once, the sink broke with `:epipe`,
  # and the new pipeline died. The player started a third one 2 seconds later, so a
  # person heard the station after a wait and saw the buffering state twice.
  #
  # The monitor goes first. Without that step this stop reaches `handle_info/2`
  # as the fault of a pipeline that no person stopped, and the player then starts
  # the old station again.
  defp stop_pipeline(%State{pipeline: pipeline, monitor: monitor} = state) do
    if monitor, do: Process.demonitor(monitor, [:flush])

    # `force?: true` ends a pipeline that does not answer. A stereo must play the
    # next station, and it must not wait for ever.
    case Membrane.Pipeline.terminate(pipeline, timeout: @terminate_timeout, force?: true) do
      :ok -> :ok
      {:error, :timeout} -> Logger.warning("The pipeline did not stop. Killing it.")
    end

    %State{state | pipeline: nil, monitor: nil, started_at: nil}
  end

  defp restart(%State{restarts: restarts} = state) when restarts >= @max_restarts do
    store_position(state)
    Logger.error("The stream failed #{restarts} times. Giving up.")
    Event.publish(:player, %Events.Failed{reason: :too_many_restarts})
    %State{stop_pipeline(state) | restarts: 0, source: nil, item: nil}
  end

  defp restart(%State{} = state) do
    store_position(state)
    state = stop_pipeline(state)
    Event.publish(:player, %Events.Buffering{percent: 0})

    %State{
      state
      | restarts: state.restarts + 1,
        restart_timer: Process.send_after(self(), :restart, @restart_delay)
    }
  end

  # **A pending restart belongs to the stream that failed.** Anything that a person
  # then asks for supersedes it, so a start and a stop each cancel it.
  #
  # Without this the timer of a lost stream reaches a player that already plays
  # something else, and `handle_info(:restart, …)` then starts a second pipeline beside
  # the one that runs. The second `aplay` finds the card busy, its sink breaks with
  # `:epipe`, and a person who changed station inside the two seconds of the delay
  # hears nothing.
  defp cancel_restart(%State{restart_timer: nil} = state), do: state

  # **A timer that has already fired cannot be cancelled, and its message waits in the
  # mailbox.** `Process.cancel_timer/1` answers `false` for that, and the message then
  # reaches `handle_info(:restart, …)` after the person asked for something else. This
  # takes it out of the mailbox, which is the one way to stop it.
  defp cancel_restart(%State{restart_timer: timer} = state) do
    if Process.cancel_timer(timer) == false do
      receive do
        :restart -> :ok
      after
        0 -> :ok
      end
    end

    %State{state | restart_timer: nil}
  end

  defp fail(reason, %State{} = state) do
    Logger.error("The player could not start: #{inspect(reason)}")
    Event.publish(:player, %Events.Failed{reason: reason})
    {:error, reason, %State{state | pipeline: nil}}
  end

  # A resume asks the server for the bytes from a point, so the audio that arrives
  # begins there. The count therefore adds where the stream began, and a progress
  # bar shows the place in the whole track.
  defp position_ms(%State{started_at: nil, offset_ms: offset}), do: offset

  defp position_ms(%State{started_at: at, offset_ms: offset}) do
    offset + System.monotonic_time(:millisecond) - at
  end

  # A track ended by itself. A podcast marks the episode played, and a station never
  # reaches this, because a live stream that ends is a network that failed.
  #
  # The mark releases the file of the track as well, so an eviction may take it. See
  # the `:mark_played` action of `MyHiFi.Playback.Item`.
  #
  # The row stays in the queue and the mark moves past it, so a person can go back to
  # what they heard.
  defp finish(%State{item: item} = state) do
    state = stop_pipeline(state)
    Playback.mark_played(item)
    Event.publish(:player, %Events.Stopped{reason: :finished})

    advance(%State{
      state
      | playable: nil,
        stream_title: nil,
        artwork_path: nil,
        offset_ms: 0,
        position_bytes: nil
    })
  end

  # The end of one track is the start of the next one. A queue with no more
  # leaves the device with the track that ended still selected, so a person reads what
  # they heard last and a play control starts it again.
  defp advance(%State{} = state) do
    with {:ok, item} <- moved(:next),
         {:ok, source} <- Source.from_slug(item.source),
         true <- Source.enabled?(source),
         {:ok, state} <- start(source, item, state) do
      Settings.put(@last_item_key, item.id)
      state
    else
      _other -> state
    end
  end

  # `keeps_place?` of the item decides whether the place is written at all, so a
  # station keeps none and an episode keeps one. See
  # `MyHiFi.Playback.Item.Changes.KeepPlaceOnly`.
  #
  # A track that never began has no place to keep, and writing 0 would lose the
  # place that a person already had.
  # A track that keeps no place leaves nothing for a person to go back to, so a stop is
  # the end of it and its file must stop holding the card against every eviction. The
  # `:mark_played` action does this for a track that reaches its end by itself, and a
  # person who stops half way through a song reaches that path never. Such a file
  # therefore held `keep?` for ever, and each one made the card smaller.
  #
  # A track that keeps its place is the opposite. A person goes on from where they
  # stopped, on a later day, and the file must still be there. See `keeps_place?` of
  # `MyHiFi.Playback.Item`.
  defp release_file(%State{item: %{keeps_place?: false, id: id}}), do: Download.release(id)

  defp release_file(%State{}), do: :ok

  defp store_position(%State{started_at: nil}), do: :ok
  defp store_position(%State{item: nil}), do: :ok

  defp store_position(%State{item: item} = state) do
    Playback.store_position(item, %{
      position_ms: position_ms(state),
      position_bytes: state.position_bytes
    })

    :ok
  end

  # The audio of the next track arrives before a person asks for it, so the gap
  # between two tracks needs no request and no first 64 KB. See
  # `MyHiFi.Player.Prefetch` for what this does not remove.
  #
  # **A track whose own file is not whole reads nothing ahead.** Two downloads then
  # share one network, and the one that a person is hearing is the one that must not
  # wait. A cache entry of this track is the answer: `MyHiFi.Player.Download` writes
  # it when the file is whole, and never before.
  defp prefetch(%State{prefetched?: true} = state), do: state

  defp prefetch(%State{item: %{duration_ms: duration}} = state)
       when is_integer(duration) do
    if duration - position_ms(state) <= @prefetch_lead_ms and whole?(state.item) do
      ask_for_next()

      %State{state | prefetched?: true}
    else
      state
    end
  end

  defp prefetch(%State{} = state), do: state

  defp ask_for_next do
    with {:ok, row} <- Playback.queue_next_up(),
         {:ok, item} <- item(row.item_id) do
      Prefetch.ask(item)
    end
  end

  defp whole?(%{id: id}) do
    match?({:ok, _entry}, MyHiFi.Cache.fetch(Download.namespace(), id))
  end

  defp schedule_progress, do: Process.send_after(self(), :progress, @progress_interval)
end
