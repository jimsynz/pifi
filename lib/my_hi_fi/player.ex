defmodule MyHiFi.Player do
  @moduledoc """
  Plays one track at a time.

  A caller gives a source and a reference to a track, and the player asks the
  source to resolve it, builds a pipeline, and plays it. It holds one pipeline at a
  time, and it stops the old one first.

  It tells the rest of the firmware what it does on the `:player` topic. See
  `MyHiFi.Event.Player`. Nothing reads the state of this process directly, apart
  from `state/0` for a person at the console.

  ## The controls

  A pause stops the pipeline and it keeps the track selected, so a play starts the
  pipeline again at the place that the source holds. That is the resume of section 9 of
  the specification, and a pause therefore needs no mechanism of its own.

  A skip keeps the pipeline. It moves the byte that `MyHiFi.Player.FileSource` reads,
  because a start of a pipeline opens the sound card again and holds a silence of about
  one second. See `MyHiFi.Player.Skip`.

  Next and previous ask the source, which owns the order that a person sees. See
  `MyHiFi.Source.next/1`, and `MyHiFi.Source.capabilities/0` for the control that each
  source holds.

  A live stream ends when the network fails, and a person expects the music to
  come back. The player therefore starts the stream again after a short wait, and
  it gives up after a few tries.
  """

  use GenServer

  require Logger

  alias MyHiFi.Artwork
  alias MyHiFi.Event
  alias MyHiFi.Event.Player, as: Events
  alias MyHiFi.Output
  alias MyHiFi.Player.Pipeline
  alias MyHiFi.Settings

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
  @last_source_key "last_source"
  @last_ref_key "last_ref"
  @standby_key "standby"

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            source: module() | nil,
            ref: term() | nil,
            track: map() | nil,
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
            standby?: boolean()
          }

    defstruct source: nil,
              ref: nil,
              track: nil,
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
              standby?: false
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @doc """
  Play one track of one source.

  The `ref` comes from `browse/2` or `search/2` of that source.
  """
  @spec play(module(), term()) :: :ok | {:error, term()}
  def play(source, ref), do: GenServer.call(__MODULE__, {:play, source, ref}, :timer.seconds(30))

  @doc "Stop the music."
  @spec stop() :: :ok
  def stop, do: GenServer.call(__MODULE__, :stop)

  @doc """
  Stop the audio and keep the track, or start it again.

  A pause is not a stop. A stop leaves the device with nothing selected, and a pause
  leaves the track in front of the person.

  A play starts the track at the place that the source holds, so a podcast episode
  continues and a live station opens again at the current point of the stream. A play
  also leaves standby, because a person who asks for music asks the device to be
  awake.
  """
  @spec pause(boolean()) :: :ok | {:error, term()}
  def pause(paused?), do: GenServer.call(__MODULE__, {:pause, paused?}, :timer.seconds(30))

  @doc """
  Play the track after the one that plays now.

  The source holds the order. See `MyHiFi.Source.next/1`.
  """
  @spec next() :: :ok | {:error, term()}
  def next, do: GenServer.call(__MODULE__, {:move, :next}, :timer.seconds(30))

  @doc """
  Play the track before the one that plays now.

  The source holds the order. See `MyHiFi.Source.previous/1`.
  """
  @spec previous() :: :ok | {:error, term()}
  def previous, do: GenServer.call(__MODULE__, {:move, :previous}, :timer.seconds(30))

  @doc """
  Move inside the track that plays.

  `ms` is signed, so a backward skip is a negative number. The pipeline keeps playing,
  and the source reports the time that it really moved, which arrives as a
  `MyHiFi.Event.Player.Progress` event.

  A track that a person cannot move inside gives `{:error, :cannot_skip}`: a live
  stream holds no place, a source may hold no skip at all, and
  `MyHiFi.Player.Skip` reads MP3 frames alone. A track that makes no sound yet gives
  `{:error, :not_playing}`, and a pause therefore holds no skip.
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

  @doc "What the player is doing, for a person at the console."
  @spec state() :: map()
  def state, do: GenServer.call(__MODULE__, :state)

  @doc """
  The output devices, and the one that the player uses.

  The settings page shows this, so that page needs no knowledge of which output
  module the player holds.
  """
  @spec output() :: %{devices: [map()], selected: String.t() | nil}
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
  The settings key that holds the chosen output device.
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
  def handle_call({:play, source, ref}, _from, %State{} = state) do
    store_position(state)
    state = stop_pipeline(state)

    case start(source, ref, state) do
      {:ok, state} ->
        # Only a new choice goes to the settings. Leaving standby and starting the
        # stream again both use the choice that is already there.
        store_station(source, ref)
        {:reply, :ok, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call(:stop, _from, %State{} = state) do
    store_position(state)
    silence(state)
    Event.publish(:player, %Events.Stopped{reason: :requested})

    {:reply, :ok,
     %State{
       state
       | source: nil,
         ref: nil,
         track: nil,
         playable: nil,
         stream_title: nil,
         artwork_path: nil,
         offset_ms: 0,
         position_bytes: nil,
         paused?: false
     }, {:continue, {:terminate, state.pipeline, state.monitor}}}
  end

  # A pause holds a track for a person, so a device with nothing selected has nothing
  # to pause.
  @impl GenServer
  def handle_call({:pause, true}, _from, %State{source: nil} = state) do
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:pause, true}, _from, %State{pipeline: nil} = state) do
    {:reply, :ok, %State{state | paused?: true}}
  end

  # `offset_ms` holds the place, because the terminate below clears `started_at` and
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
  def handle_call({:pause, false}, _from, %State{source: nil} = state) do
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

    case start(state.source, state.ref, state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:move, _direction}, _from, %State{source: nil} = state) do
    {:reply, {:error, :nothing_selected}, state}
  end

  # A move is a play of another track of the same source, so this gives the work to the
  # clause that plays one. That clause writes the place of this track, it stops the
  # pipeline, and it keeps the new track in the settings.
  @impl GenServer
  def handle_call({:move, direction}, from, %State{} = state) do
    with :ok <- held(state.source, direction),
         {:ok, ref} <- beside(state, direction) do
      handle_call({:play, state.source, ref}, from, waking(state))
    else
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

    case start(state.source, state.ref, state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call(:state, _from, %State{} = state) do
    {:reply,
     %{
       source: state.source,
       track: state.track,
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
    output = Output.module()

    {:reply, %{devices: output.devices(), selected: chosen_device()}, state}
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
      duration_ms: state.track && state.track.duration_ms
    })

    schedule_progress()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:pipeline_playing, pipeline}, %State{pipeline: pipeline} = state) do
    artwork_path = artwork_path(state.track)

    Event.publish(:player, %Events.Started{
      source: state.source,
      track: state.track,
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

  # `MyHiFi.Player.FileSource` reports the byte that it has read. The player holds
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
      duration_ms: state.track && state.track.duration_ms
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

  @impl GenServer
  def handle_info(:restart, %State{source: source, ref: ref} = state)
      when source != nil and ref != nil do
    case start(source, ref, state) do
      {:ok, state} -> {:noreply, state}
      {:error, _reason, state} -> {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(message, state) do
    Logger.debug("Player ignoring #{inspect(message)}")
    {:noreply, state}
  end

  defp start(source, ref, %State{} = state) do
    state = cancel_restart(state)

    with {:ok, playable} <- source.resolve(ref),
         {:ok, track} <- source.track(ref),
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
               ref: ref,
               track: track,
               playable: playable,
               pipeline: pipeline,
               monitor: monitor,
               stream_title: nil,
               artwork_path: nil,
               started_at: nil,
               offset_ms: playable.position_ms,
               position_bytes: playable[:position_bytes],
               paused?: false
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
  # firmware holds `aplay`, and `aplay` holds a sound card, so a test of what the
  # player does at the end of a track cannot use it: the host of a build server
  # holds no card. Nothing sets this in production.
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

  # A person chooses a device, and that choice stays in the settings. A DAC can
  # leave the device, so a choice that names an absent card gives way to the first
  # card that is present. Silence is worse than the wrong socket.
  defp sink(%State{}) do
    output = Output.module()
    devices = output.devices()
    chosen = chosen_device()

    case Enum.find(devices, List.first(devices), &(&1.id == chosen)) do
      %{id: id} -> {:ok, output.sink_spec(id)}
      nil -> {:error, :no_output_device}
    end
  end

  # A page shows the local copy of a logo, and never the address of the station.
  # The content security policy of the device holds `'self'` alone. A logo that the
  # cache does not hold arrives in a later event, from `MyHiFi.Artwork.Worker`.
  defp artwork_path(%{artwork: url}) do
    case Artwork.name(url) do
      nil ->
        Artwork.Worker.enqueue(url)
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

  # The source owns the order, and `capabilities/0` says whether it holds one at all.
  # A user interface reads the same list, so a control that gives this error is a
  # control that the interface drew dead.
  defp held(source, direction) do
    if direction in source.capabilities(), do: :ok, else: {:error, :not_supported}
  end

  defp beside(%State{source: source, ref: ref}, :next), do: source.next(ref)
  defp beside(%State{source: source, ref: ref}, :previous), do: source.previous(ref)

  # A skip needs four things: a source that holds one, a track with an end, a file to
  # read, and a format that `MyHiFi.Player.Skip` reads. `:download` is the transport
  # that gives the file, and `MyHiFi.Player.FileSource` is the element that moves. All
  # four give one answer to a person: this track holds no skip.
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

  # A source names its own ref, so nothing here turns stored bytes back into a
  # term. See `MyHiFi.Source.ref_to_string/1`.
  defp store_station(source, ref) do
    case source.ref_to_string(ref) do
      {:ok, name} ->
        Settings.put(@last_source_key, inspect(source))
        Settings.put(@last_ref_key, name)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  # A restored track is a paused track. A person then reads the name of the station
  # and a play control, and section 9 asks for that: the device selects the station and
  # plays nothing.
  defp restore_station(%State{} = state) do
    with {:ok, source} <- stored_source(),
         {:ok, name} <- stored_value(@last_ref_key),
         {:ok, ref} <- source.ref_from_string(name),
         {:ok, track} <- source.track(ref) do
      %State{state | source: source, ref: ref, track: track, paused?: true}
    else
      _other -> state
    end
  end

  # Only a source that this firmware holds can come back. A name from the
  # settings therefore never makes an atom, and a source that a later version
  # removes leaves the device with nothing selected.
  defp stored_source do
    with {:ok, name} <- stored_value(@last_source_key),
         source when not is_nil(source) <-
           Enum.find(MyHiFi.Source.all(), &(inspect(&1) == name)) do
      {:ok, source}
    else
      _other -> :error
    end
  end

  defp stored_standby?, do: stored_value(@standby_key) == {:ok, "true"}

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
    state = stop_pipeline(state)

    case start(state.source, state.ref, state) do
      {:ok, state} -> state
      {:error, _reason, state} -> state
    end
  end

  # `aplay` holds the sound card, so closing its port is what makes the room quiet.
  # The pipeline may take its time after that. A call that no pipeline answers is a
  # pipeline that is already wedged, and the forced terminate of `stop_pipeline/1`
  # holds that case.
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

  # This waits for the old pipeline, and the wait is what makes a change of
  # station work. The sink holds `aplay`, and `aplay` holds the sound card. A
  # pipeline that starts while the old one still runs therefore finds the card
  # busy, its `aplay` stops at once, the sink breaks with `:epipe`, and the new
  # pipeline dies. The player then starts a third one 2 seconds later, so a person
  # hears the station after a wait and sees the buffering state twice.
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
    %State{stop_pipeline(state) | restarts: 0, source: nil, ref: nil}
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

  defp cancel_restart(%State{restart_timer: timer} = state) do
    Process.cancel_timer(timer)
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

  # A track ended by itself. The source holds what that means: a podcast marks the
  # episode played, and a station never reaches this.
  defp finish(%State{source: source, ref: ref} = state) do
    state = stop_pipeline(state)
    source.finished(ref)
    Event.publish(:player, %Events.Stopped{reason: :finished})

    %State{
      state
      | track: nil,
        playable: nil,
        stream_title: nil,
        artwork_path: nil,
        offset_ms: 0,
        position_bytes: nil
    }
  end

  # The source decides what a place means, and this process holds no knowledge of
  # that. It gives the number and moves on, and a source that keeps no place gives
  # `:ok`. Nothing waits on the answer, because a stop must be quick.
  #
  # A track that never began has no place to keep, and writing 0 would lose the
  # place that a person already had.
  defp store_position(%State{started_at: nil}), do: :ok
  defp store_position(%State{source: nil}), do: :ok

  defp store_position(%State{source: source, ref: ref} = state) do
    source.store_position(ref, %{ms: position_ms(state), bytes: state.position_bytes})
    :ok
  end

  defp schedule_progress, do: Process.send_after(self(), :progress, @progress_interval)
end
