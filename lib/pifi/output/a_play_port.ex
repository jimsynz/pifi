defmodule PiFi.Output.APlayPort do
  @moduledoc """
  Holds `aplay` open across more than one pipeline, and sums two of them during a
  crossfade.

  This firmware builds a pipeline for each playable, and a pipeline used to build its
  own `aplay` with it. **A start of `aplay` opens the sound card, and that costs a
  silence of about one second**, so a person heard a gap between one track of an album
  and the next, and `PiFi.Player.Prefetch` could remove the wait for the network and
  not that gap.

  It also cut the end of every track. `PiFi.Output.APlaySink` ended the program when
  its input ended, and ALSA keeps about half a second of sound, so the last half second
  of a track went with the program that was going to play it.

  This process owns the port instead, and it outlives every pipeline. A sink asks for
  the program that it needs, writes the samples to what it gets, and stops writing at
  the end of a track. The card stays open, the queue plays out, and the next pipeline
  writes to the same port.

  ## The arguments are the name of the sound

  `hold/2` takes a program and its arguments, and it keeps one port for one of those.
  **The format of the audio is on the command line of `aplay`**, so two tracks of one
  rate give the same arguments and one port, and a track of another rate gives other
  arguments and a new port. An album therefore plays through one port, and a change
  from a station at 24000 Hz to a track at 44100 Hz costs what it always cost.

  A port for every format would need a resampler in front of the sink, and this
  firmware needs none: `rate48` of `/etc/asound.conf` converts from the rate that
  `aplay` **names** to the 48000 Hz that the card runs at, so naming 48000 Hz for
  44100 Hz audio plays the music 8.8% fast. See `PiFi.Output.Alsa`.

  ## Why a process and not a pipeline that lives longer

  Membrane can add and remove children while a pipeline runs, and that would put the
  skip, the resume, the prefetch and the restart of every playable into one graph. The
  port needs none of that. **A process that does not own a port may write to it**, and
  the busy limits below still suspend whoever writes, so the pacing of the pipeline is
  unchanged and every other part of the player stays as it is. A measurement on
  2026-09-07 confirmed both.

  ## The crossfade

  A fade needs two tracks playing at once, and one sound card cannot take two streams.
  This process is the place where they meet, because it is the one part of the audio
  path that outlives a pipeline and already holds the port.

  `PiFi.Player` calls `fade/1` with the length, tells the sink of the track that is
  ending that it is `:outgoing`, and starts the pipeline of the next track with its
  sink told `:incoming`. Each sink then calls `blend/2` in the place of writing to the
  port itself, and this pairs the two buffers, calls `PiFi.Output.Mixer.mix/4` on the
  frames that both sides have, and writes the answer.

  **A caller waits until its bytes are used**, which is what keeps the two pipelines in
  step: a decoder that runs ahead of the other one blocks in `blend/2` until the slower
  side catches up, and the pair then blocks on the busy limits of the port in the way
  that a single stream always did.

  A fade ends in one of two ways. It runs to its length, and then the outgoing sink
  becomes a null sink and the incoming one goes back to writing to the port directly.
  Or something makes it impossible, and this abandons it: the sound is then what it
  would have been with no crossfade at all, which is one track stopping and the next
  starting. `abandon/2` is every one of those reasons in one place.

  **A stop can wait longer during a fade.** `Port.command/2` blocks the caller when the
  queue of the port is full, and during a fade that caller is this process, so
  `close/0` waits behind it. The busy limits below bound that at about four tenths of a
  second of audio.

  ## What still ends the sound at once

  A person who stops, pauses or puts the device in standby wants silence now, so
  `close/0` ends the program. `PiFi.Player` sends `:silence` to the sink for each of
  those, and the sink calls this. The next play opens the card again.
  """

  use GenServer

  require Logger

  alias Membrane.RawAudio
  alias PiFi.Output.Mixer

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

  @typedoc """
  Which side of a crossfade a sink is on. `:outgoing` is the track that is ending.
  """
  @type role :: :outgoing | :incoming

  @doc "Start the holder of the port."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The port of one program, opened now or held from before.

  It returns the port that it already keeps when the program and the arguments are the
  ones that it opened. It ends that program and opens the new one otherwise.

  **A crossfade cannot survive the second case**, because the arguments name the format
  and two formats cannot share a card. The fade is abandoned, and a person hears the
  gap that they would have heard with the setting turned off.
  """
  @spec hold(String.t(), [String.t()]) :: {:ok, port()} | {:error, term()}
  def hold(program, arguments) do
    GenServer.call(__MODULE__, {:hold, program, arguments})
  end

  @doc """
  End the program now, so the room is quiet.

  **Closing the port alone is not enough.** `aplay` then sees the end of its input and
  plays what it already has, which is about half a second of ALSA and whatever the
  pipeline sends while it stops, so a person who pressed stop waited seconds for
  silence.
  """
  @spec close() :: :ok
  def close, do: GenServer.call(__MODULE__, :close)

  @doc "The program and the arguments of the port that this keeps, or `nil` for none."
  @spec held() :: {String.t(), [String.t()]} | nil
  def held, do: GenServer.call(__MODULE__, :held)

  @doc """
  Begin a crossfade of this many milliseconds.

  `PiFi.Player` calls this before it tells the two sinks which side they are on. It
  needs a port already open, because the track that is ending is playing through one.
  """
  @spec fade(pos_integer()) :: :ok | {:error, :no_port}
  def fade(milliseconds) when is_integer(milliseconds) and milliseconds > 0 do
    GenServer.call(__MODULE__, {:fade, milliseconds})
  end

  @doc """
  Stop the crossfade and leave the sound as it would have been without one.

  `PiFi.Player` calls this when a person presses next in the middle of a fade: they
  asked for the track after this one, and finishing a fade into a track that they no
  longer want is the wrong answer.
  """
  @spec cancel_fade() :: :ok
  def cancel_fade, do: GenServer.call(__MODULE__, :cancel_fade)

  @doc """
  Say which side of the fade a sink is on, and what its audio looks like.

  The outgoing side registers first and its format decides the fade: the sample format
  has to be one that `PiFi.Output.Mixer` can sum, and the rate turns the length in
  milliseconds into a number of frames. The incoming side has to match it.
  """
  @spec fading(role(), RawAudio.t()) :: :ok | {:error, term()}
  def fading(role, format), do: GenServer.call(__MODULE__, {:fading, role, format})

  @doc """
  Give one buffer to the fade, and wait until it is used.

  It returns `:finished` when the fade ran to its length. The incoming sink then writes
  to the port directly again, and the outgoing one is at no volume at all, so it becomes
  a null sink. `:cancelled` means the fade was abandoned before it got there, and then
  **both sides go back to writing to the port as they were**: a fade that gave up must
  not silence a track that is still playing. `:closed` means the program went.

  **The wait is the point.** Two pipelines decode at the speed of their own source, and
  the one that runs ahead has to stop until the other one has the frames to pair with.
  """
  @spec blend(role(), binary()) :: :ok | :finished | :cancelled | :closed
  def blend(role, payload), do: GenServer.call(__MODULE__, {:blend, role, payload}, :infinity)

  @doc """
  Note that the stream of one side of the fade ended.

  An outgoing track that is shorter than the fade leaves the rest of the ramp with
  nothing to take down, so the fade carries on against silence and the incoming track
  still arrives at full gain at the end of it. An incoming track that ends inside the
  fade has nothing left to fade in, so the fade is abandoned.
  """
  @spec fade_ended(role()) :: :ok
  def fade_ended(role), do: GenServer.call(__MODULE__, {:fade_ended, role})

  @doc """
  Note that a sink wrote the last samples of a track.

  `PiFi.Output.APlaySink` calls this at the end of its stream, and `wrote_first/0` at
  the start of the next one. **This process is the one that sees both**, because a
  pipeline holds the sink of one track alone and the program outlives every pipeline.

  It is a cast, so the sink writes samples and never waits for this.
  """
  @spec wrote_last() :: :ok
  def wrote_last, do: GenServer.cast(__MODULE__, {:wrote_last, System.monotonic_time()})

  @doc """
  Note that a sink wrote the first samples of a track.

  It publishes `[:pifi, :player, :gap]` with the time since the last samples of the
  track before, which is the silence that a person hears between two tracks of an album.
  ALSA still holds about half a second when those last samples arrive, so a gap that is
  shorter than that queue is one that no person hears.

  **A stop publishes nothing.** `close/0` ends the program, and the silence after it is
  what a person asked for.
  """
  @spec wrote_first() :: :ok
  def wrote_first, do: GenServer.cast(__MODULE__, {:wrote_first, System.monotonic_time()})

  @doc false
  @impl GenServer
  def init(opts) do
    # A firmware that stops must not leave `aplay` holding the card.
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       port: nil,
       key: nil,
       last_at: nil,
       fade: nil,
       last_fade: nil,
       busy_limits: Keyword.get(opts, :busy_limits, @busy_limits)
     }}
  end

  @doc false
  @impl GenServer
  def handle_call({:hold, program, arguments}, _from, state) do
    case state do
      %{key: {^program, ^arguments}, port: port} when is_port(port) ->
        if alive?(port) do
          {:reply, {:ok, port}, state}
        else
          open(program, arguments, ended(abandon(state, "the program was gone")))
        end

      _other ->
        open(program, arguments, ended(abandon(state, "the format changed")))
    end
  end

  def handle_call(:close, _from, state) do
    {:reply, :ok, ended(abandon(state, "the sound stopped"))}
  end

  def handle_call(:held, _from, state), do: {:reply, state.key, state}

  def handle_call({:fade, _milliseconds}, _from, %{port: nil} = state) do
    {:reply, {:error, :no_port}, state}
  end

  def handle_call({:fade, milliseconds}, _from, state) do
    deadline = make_ref()

    # Nothing else notices a fade that both sides stopped calling, and a sink that waits
    # in `blend/2` for a side that never registers would wait for ever.
    Process.send_after(self(), {:fade_deadline, deadline}, milliseconds * 2 + 1_000)

    fade = %{
      length_ms: milliseconds,
      deadline: deadline,
      format: nil,
      frame_size: nil,
      total: nil,
      done: 0,
      outgoing: %{from: nil, bytes: <<>>, ended?: false},
      incoming: %{from: nil, bytes: <<>>}
    }

    {:reply, :ok, %{abandon(state, "another one started") | fade: fade, last_fade: nil}}
  end

  def handle_call(:cancel_fade, _from, state) do
    {:reply, :ok, abandon(state, "a person asked for another track")}
  end

  def handle_call({:fading, _role, _format}, _from, %{fade: nil} = state) do
    {:reply, {:error, :no_fade}, state}
  end

  def handle_call({:fading, :outgoing, format}, _from, %{fade: fade} = state) do
    if Mixer.supported?(format.sample_format) do
      fade = %{
        fade
        | format: format.sample_format,
          frame_size: RawAudio.frame_size(format),
          total: div(fade.length_ms * format.sample_rate, 1_000)
      }

      {:reply, :ok, %{state | fade: fade}}
    else
      {:reply, {:error, :unsupported_format},
       abandon(state, "#{format.sample_format} is not a format that this can sum")}
    end
  end

  def handle_call({:fading, :incoming, format}, _from, %{fade: fade} = state) do
    if fade.format == format.sample_format and fade.frame_size == RawAudio.frame_size(format) do
      {:reply, :ok, state}
    else
      {:reply, {:error, :format_changed}, abandon(state, "the two tracks are not the same shape")}
    end
  end

  # The fade is over and this side has not been told yet. A fade that ran to its length
  # leaves the outgoing track at no volume, so its samples go nowhere; a fade that was
  # abandoned leaves it playing, so they go to the card.
  def handle_call(
        {:blend, :outgoing, _payload},
        _from,
        %{fade: nil, last_fade: :finished} = state
      ) do
    {:reply, :finished, state}
  end

  def handle_call({:blend, _role, payload}, _from, %{fade: nil} = state) do
    {:reply, reply_for(command(state.port, payload), state.last_fade), state}
  end

  def handle_call({:blend, role, payload}, from, %{fade: fade} = state) do
    side = Map.fetch!(fade, role)
    fade = Map.put(fade, role, %{side | from: from, bytes: side.bytes <> payload})

    {:noreply, pair(%{state | fade: fade})}
  end

  def handle_call({:fade_ended, _role}, _from, %{fade: nil} = state), do: {:reply, :ok, state}

  def handle_call({:fade_ended, :incoming}, _from, state) do
    {:reply, :ok, abandon(state, "the next track ended inside it")}
  end

  def handle_call({:fade_ended, :outgoing}, _from, %{fade: fade} = state) do
    reply_to(fade.outgoing, :finished)

    fade = %{fade | outgoing: %{from: nil, bytes: <<>>, ended?: true}}

    {:reply, :ok, pair(%{state | fade: fade})}
  end

  @doc false
  @impl GenServer
  def handle_cast({:wrote_last, at}, state), do: {:noreply, %{state | last_at: at}}

  # A first write with no last one before it is a person who pressed play, and that
  # wait is what `[:pifi, :player, :sound]` already holds.
  def handle_cast({:wrote_first, _at}, %{last_at: nil} = state), do: {:noreply, state}

  def handle_cast({:wrote_first, at}, %{last_at: last_at} = state) do
    :telemetry.execute(
      [:pifi, :player, :gap],
      %{duration: at - last_at},
      %{device: state.key}
    )

    {:noreply, %{state | last_at: nil}}
  end

  # **A port that has closed is still a port, and `is_port/1` says so.** `aplay` writing
  # to a Bluetooth device that was switched off does not always exit with a status, so
  # nothing cleared what is held, and the next play was handed a port with no program
  # behind it: `aplay is gone, so this pipeline ends`, five times, and then the track
  # was dropped. Pressing play on the device afterwards failed the same way.
  # `Port.info/1` is the one answer that distinguishes the two.
  defp alive?(port), do: Port.info(port) != nil

  @doc false
  @impl GenServer
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("aplay stopped with status #{status}.")

    {:noreply, %{abandon(state, "the program stopped") | port: nil, key: nil}}
  end

  def handle_info({:fade_deadline, deadline}, %{fade: %{deadline: deadline}} = state) do
    {:noreply, abandon(state, "one side of it never arrived")}
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

  defp ended(%{port: nil} = state), do: %{state | last_at: nil}

  defp ended(%{port: port} = state) do
    stop_program(port)
    close_port(port)

    %{state | port: nil, key: nil, last_at: nil}
  end

  # **Everything that makes a fade impossible ends here**, so there is one description
  # of what a person then hears: the track that was ending keeps playing to its end and
  # the next one starts after it, which is what this firmware did before the setting
  # existed.
  #
  # The bytes that the incoming side is holding go to the card first. They are at most
  # one buffer, and dropping them would be a click at the moment that the fade gave up.
  defp abandon(%{fade: nil} = state, _reason), do: state

  defp abandon(%{fade: fade} = state, reason) do
    Logger.info("The crossfade stopped, because #{reason}.")

    _result = command(state.port, fade.incoming.bytes)

    reply_to(fade.outgoing, :cancelled)
    reply_to(fade.incoming, :cancelled)

    %{state | fade: nil, last_fade: :cancelled}
  end

  # The gain of the outgoing track walks from 1.0 at the first frame of the fade to 0.0
  # at the last one, and `PiFi.Output.Mixer` gives the incoming track the rest. This
  # takes the gain at the ends of the frames that both sides have now, so a buffer of
  # any size lands on the same ramp.
  defp pair(%{fade: fade} = state) do
    case pairable(fade) do
      0 -> state
      count -> blend_frames(state, count)
    end
  end

  defp pairable(%{frame_size: nil}), do: 0

  defp pairable(%{outgoing: %{ended?: true}, incoming: incoming, frame_size: size}) do
    div(byte_size(incoming.bytes), size) * size
  end

  defp pairable(%{outgoing: outgoing, incoming: incoming, frame_size: size}) do
    div(min(byte_size(outgoing.bytes), byte_size(incoming.bytes)), size) * size
  end

  defp blend_frames(%{fade: fade} = state, count) do
    {outgoing, outgoing_rest} = chunk(fade.outgoing, count)
    <<incoming::binary-size(^count), incoming_rest::binary>> = fade.incoming.bytes

    frames = div(count, fade.frame_size)
    mixed = Mixer.mix(outgoing, incoming, fade.format, gains(fade, frames))

    case command(state.port, mixed) do
      :closed ->
        abandon(state, "the program stopped")

      :ok ->
        fade = %{
          fade
          | done: fade.done + frames,
            outgoing: %{fade.outgoing | bytes: outgoing_rest},
            incoming: %{fade.incoming | bytes: incoming_rest}
        }

        advanced(state, fade)
    end
  end

  # A track that ended gives silence for the rest of the ramp, and 0 is silence for
  # every format that `PiFi.Output.Mixer` sums.
  defp chunk(%{ended?: true}, count), do: {:binary.copy(<<0>>, count), <<>>}

  defp chunk(%{bytes: bytes}, count) do
    <<taken::binary-size(^count), rest::binary>> = bytes

    {taken, rest}
  end

  defp advanced(state, %{done: done, total: total} = fade) when done >= total do
    # Whatever the incoming side has left is past the end of the ramp, so it plays as
    # itself.
    _result = command(state.port, fade.incoming.bytes)

    reply_to(fade.outgoing, :finished)
    reply_to(fade.incoming, :finished)

    %{state | fade: nil, last_fade: :finished}
  end

  defp advanced(state, fade) do
    fade =
      fade
      |> settle(:outgoing)
      |> settle(:incoming)

    %{state | fade: fade}
  end

  # A side whose buffer is used up may decode the next one. A side that still holds
  # bytes waits, which is what keeps the two pipelines together.
  defp settle(fade, role) do
    case Map.fetch!(fade, role) do
      %{bytes: <<>>, from: from} = side when from != nil ->
        GenServer.reply(from, :ok)
        Map.put(fade, role, %{side | from: nil})

      _other ->
        fade
    end
  end

  defp reply_to(%{from: nil}, _answer), do: :ok
  defp reply_to(%{from: from}, answer), do: GenServer.reply(from, answer)

  defp gains(%{done: done, total: total}, frames) do
    {gain(done, total), gain(done + frames - 1, total)}
  end

  defp gain(index, total) when index >= total, do: 0.0
  defp gain(index, total), do: 1.0 - index / total

  defp reply_for(:closed, _last_fade), do: :closed
  defp reply_for(:ok, :cancelled), do: :cancelled
  defp reply_for(:ok, _last_fade), do: :finished

  defp command(nil, _payload), do: :closed
  defp command(_port, <<>>), do: :ok

  defp command(port, payload) do
    Port.command(port, payload)

    :ok
  rescue
    ArgumentError -> :closed
  end

  # **A port that has already gone is the state that this wants.** `stop_program/1`
  # ends the program, and the port of a program that ended closes by itself, so a read
  # of `Port.info/1` and a close after it are two steps with a race between them. A
  # build on 2026-09-14 raised `ArgumentError` in that gap.
  #
  # **The raise mattered because of which process this is.** It holds the sound card
  # across every pipeline, and a person who presses stop calls this. A stop that killed
  # the holder of the card would leave the next play with no port and no program.
  defp close_port(port) do
    Port.close(port)

    :ok
  rescue
    ArgumentError -> :ok
  end

  # The program owns the sound card and it reads at the rate of the clock of the DAC,
  # so ending it is what makes the room quiet. A measurement on 2026-08-21 gave 35 to
  # 245 ms from a stop to silence.
  defp stop_program(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", ["-TERM", to_string(os_pid)])
      nil -> :ok
    end
  end
end
