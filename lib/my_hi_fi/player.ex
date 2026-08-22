defmodule MyHiFi.Player do
  @moduledoc """
  Plays one track at a time.

  A caller gives a source and a reference to a track, and the player asks the
  source to resolve it, builds a pipeline, and plays it. It holds one pipeline at a
  time, and it stops the old one first.

  It tells the rest of the firmware what it does on the `:player` topic. See
  `MyHiFi.Event.Player`. Nothing reads the state of this process directly, apart
  from `state/0` for a person at the console.

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
  @max_restarts 5
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
            restarts: non_neg_integer(),
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
              restarts: 0,
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
  @impl GenServer
  def handle_continue(:restore, %State{} = state) do
    {:noreply, restore_station(%State{state | standby?: stored_standby?()})}
  end

  @impl GenServer
  def handle_call({:play, source, ref}, _from, %State{} = state) do
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
    state = stop_pipeline(state)
    Event.publish(:player, %Events.Stopped{reason: :requested})

    {:reply, :ok,
     %State{
       state
       | source: nil,
         ref: nil,
         track: nil,
         playable: nil,
         stream_title: nil,
         artwork_path: nil
     }}
  end

  @impl GenServer
  def handle_call({:standby, true}, _from, %State{} = state) do
    state = stop_pipeline(state)
    Settings.put(@standby_key, "true")
    Event.publish(:player, %Events.Standby{entered?: true})
    {:reply, :ok, %State{state | standby?: true, stream_title: nil}}
  end

  @impl GenServer
  def handle_call({:standby, false}, _from, %State{source: nil} = state) do
    Settings.put(@standby_key, "false")
    Event.publish(:player, %Events.Standby{entered?: false})
    {:reply, :ok, %State{state | standby?: false}}
  end

  @impl GenServer
  def handle_call({:standby, false}, _from, %State{} = state) do
    Settings.put(@standby_key, "false")
    Event.publish(:player, %Events.Standby{entered?: false})

    case start(state.source, state.ref, %State{state | standby?: false}) do
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
      live?: live?(state)
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
    Logger.info("The stream ended. Starting it again.")
    {:noreply, restart(state)}
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
               started_at: nil
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
  defp start_pipeline(playable, sink, _state) do
    case Membrane.Pipeline.start(Pipeline, %{
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

  defp restore_station(%State{} = state) do
    with {:ok, source} <- stored_source(),
         {:ok, name} <- stored_value(@last_ref_key),
         {:ok, ref} <- source.ref_from_string(name),
         {:ok, track} <- source.track(ref) do
      %State{state | source: source, ref: ref, track: track}
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
    state = stop_pipeline(state)

    case start(state.source, state.ref, state) do
      {:ok, state} -> state
      {:error, _reason, state} -> state
    end
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
    Logger.error("The stream failed #{restarts} times. Giving up.")
    Event.publish(:player, %Events.Failed{reason: :too_many_restarts})
    %State{stop_pipeline(state) | restarts: 0, source: nil, ref: nil}
  end

  defp restart(%State{} = state) do
    state = stop_pipeline(state)
    Event.publish(:player, %Events.Buffering{percent: 0})
    Process.send_after(self(), :restart, @restart_delay)
    %State{state | restarts: state.restarts + 1}
  end

  defp fail(reason, %State{} = state) do
    Logger.error("The player could not start: #{inspect(reason)}")
    Event.publish(:player, %Events.Failed{reason: reason})
    {:error, reason, %State{state | pipeline: nil}}
  end

  defp position_ms(%State{started_at: nil}), do: 0
  defp position_ms(%State{started_at: at}), do: System.monotonic_time(:millisecond) - at

  defp schedule_progress, do: Process.send_after(self(), :progress, @progress_interval)
end
