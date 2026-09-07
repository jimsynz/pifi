defmodule MyHiFi.Output.APlayPort do
  @moduledoc """
  Holds `aplay` open across more than one pipeline.

  This firmware builds a pipeline for each playable, and a pipeline used to build its
  own `aplay` with it. **A start of `aplay` opens the sound card, and that holds a
  silence of about one second**, so a person heard a gap between one track of an album
  and the next, and `MyHiFi.Player.Prefetch` could remove the wait for the network and
  not that gap.

  It also cut the end of every track. `MyHiFi.Output.APlaySink` ended the program when
  its input ended, and ALSA holds about half a second of sound, so the last half second
  of a track went with the program that was going to play it.

  This process owns the port instead, and it outlives every pipeline. A sink asks for
  the program that it needs, writes the samples to what it gets, and stops writing at
  the end of a track. The card stays open, the queue plays out, and the next pipeline
  writes to the same port.

  ## The arguments are the name of the sound

  `hold/2` takes a program and its arguments, and it holds one port for one of those.
  **The format of the audio is on the command line of `aplay`**, so two tracks of one
  rate give the same arguments and one port, and a track of another rate gives other
  arguments and a new port. An album therefore plays through one port, and a change
  from a station at 24000 Hz to a track at 44100 Hz costs what it always cost.

  A port for every format would need a resampler in front of the sink, and this
  firmware holds none: `rate48` of `/etc/asound.conf` converts from the rate that
  `aplay` **names** to the 48000 Hz that the card runs at, so naming 48000 Hz for
  44100 Hz audio plays the music 8.8% fast. See `MyHiFi.Output.Alsa`.

  ## Why a process and not a pipeline that lives longer

  Membrane can add and remove children while a pipeline runs, and that would put the
  skip, the resume, the prefetch and the restart of every playable into one graph. The
  port needs none of that. **A process that does not own a port may write to it**, and
  the busy limits below still suspend whoever writes, so the pacing of the pipeline is
  unchanged and every other part of the player stays as it is. A measurement on
  2026-09-07 confirmed both.

  ## What still ends the sound at once

  A person who stops, pauses or puts the device in standby wants silence now, so
  `close/0` ends the program. `MyHiFi.Player` sends `:silence` to the sink for each of
  those, and the sink calls this. The next play opens the card again.
  """

  use GenServer

  require Logger

  # How many bytes of samples may wait in the queue of the port. `Port.command/2`
  # blocks above the high mark and it runs again below the low one, so this is the lead
  # that a pipeline may hold over the sound. 44100 Hz of `s24le` stereo is 264,600
  # bytes each second, so 128 KB is under half a second and 32 KB is about a tenth of
  # one.
  #
  # **Without a limit the queue of a port has none.** `Port.command/2` never blocks,
  # nothing pushes back, and a read on 2026-08-24 measured the reader of the file 31
  # seconds in front of what a person heard, which put a resume 31 seconds past the
  # place that they stopped at. This is what makes `position_bytes` of an episode name
  # the place that a person heard.
  @busy_limits {32 * 1024, 128 * 1024}

  @doc "Start the holder of the port."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The port of one program, opened now or held from before.

  It gives the port that it holds when the program and the arguments are the ones that
  it holds. It ends the program that it held and opens the new one otherwise.
  """
  @spec hold(String.t(), [String.t()]) :: {:ok, port()} | {:error, term()}
  def hold(program, arguments) do
    GenServer.call(__MODULE__, {:hold, program, arguments})
  end

  @doc """
  End the program now, so the room is quiet.

  **Closing the port alone is not enough.** `aplay` then sees the end of its input and
  plays what it already holds, which is about half a second of ALSA and whatever the
  pipeline sends while it stops, so a person who pressed stop waited seconds for
  silence.
  """
  @spec close() :: :ok
  def close, do: GenServer.call(__MODULE__, :close)

  @doc "The program and the arguments of the port that this holds, or `nil` for none."
  @spec held() :: {String.t(), [String.t()]} | nil
  def held, do: GenServer.call(__MODULE__, :held)

  @doc false
  @impl GenServer
  def init(opts) do
    # A firmware that stops must not leave `aplay` holding the card.
    Process.flag(:trap_exit, true)

    {:ok, %{port: nil, key: nil, busy_limits: Keyword.get(opts, :busy_limits, @busy_limits)}}
  end

  @doc false
  @impl GenServer
  def handle_call({:hold, program, arguments}, _from, state) do
    case state do
      %{key: {^program, ^arguments}, port: port} when is_port(port) ->
        {:reply, {:ok, port}, state}

      _other ->
        open(program, arguments, ended(state))
    end
  end

  def handle_call(:close, _from, state), do: {:reply, :ok, ended(state)}

  def handle_call(:held, _from, state), do: {:reply, state.key, state}

  @doc false
  @impl GenServer
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("aplay stopped with status #{status}.")

    {:noreply, %{state | port: nil, key: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @impl GenServer
  def terminate(_reason, state) do
    ended(state)

    :ok
  end

  defp open(program, arguments, state) do
    case System.find_executable(program) do
      nil ->
        {:reply, {:error, {:no_program, program}}, state}

      path ->
        port =
          Port.open({:spawn_executable, path}, [
            :binary,
            :exit_status,
            {:busy_limits_port, state.busy_limits},
            args: arguments
          ])

        {:reply, {:ok, port}, %{state | port: port, key: {program, arguments}}}
    end
  end

  defp ended(%{port: nil} = state), do: state

  defp ended(%{port: port} = state) do
    stop_program(port)

    if Port.info(port), do: Port.close(port)

    %{state | port: nil, key: nil}
  end

  # The program holds the sound card and it reads at the rate of the clock of the DAC,
  # so ending it is what makes the room quiet. A measurement on 2026-08-21 gave 35 to
  # 245 ms from a stop to silence.
  defp stop_program(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", ["-TERM", to_string(os_pid)])
      nil -> :ok
    end
  end
end
