defmodule PiFi.Output.APlaySink do
  @moduledoc """
  A Membrane sink that plays raw audio through `aplay`.

  The Nerves system ships `alsa-lib`, `aplay` and `amixer`, and no other audio
  software. `membrane_alsa_plugin` does not exist, so this sink writes the samples to
  `aplay` through an Erlang port.

  `busy_limits_port` is what gives the pacing. `aplay` reads at the rate of the clock
  of the DAC, and with that option `Port.command/2` blocks this element once the queue
  of the port is full. The demand of Membrane then stops reaching the decoder, and the
  whole pipeline runs at the speed of the hardware.
  `PiFi.Output.APlayPort` names the limits and the measurement that decided them.

  `aplay` starts again when the stream format changes, because the format is on
  the command line and not in the stream.

  ## The program outlives this element

  **`PiFi.Output.APlayPort` owns the port, and this element borrows it.** A start of
  `aplay` opens the sound card and costs a silence of about one second, so a program of
  its own for each pipeline gave a person a gap between one track and the next, and it
  cut the half second that ALSA still held at the end of every track.

  This element therefore asks that process for the program that its format needs,
  writes the samples to what it gets, and **writes nothing more when its input ends**.
  The card stays open, the queue plays out, and the next pipeline writes to the same
  port. A person who stops, pauses or asks for standby gets `:silence`, and that ends
  the program at once.

  A process that does not own a port may write to it, and the busy limits of that
  process still suspend whoever writes, so the pacing above is unchanged.

  ## During a crossfade it writes to nothing

  A fade needs two tracks playing at once, and a sound card takes one stream, so the
  two sinks cannot both write to the port. `PiFi.Player` tells one of them `:fade_out`
  and the other `:fade_in`, and each then gives its samples to
  `PiFi.Output.APlayPort.blend/2`, which pairs them, sums them on the ramp and writes
  the answer. The call waits until the bytes are used, so the pacing is what it always
  was and the slower of the two decoders sets the speed of both.

  ## It writes whole frames, and that is what keeps the next track clean

  **A track that leaves a part of a frame in the port turns every sample after it into
  noise.** `aplay` reads a stream of frames of a fixed width, and it holds no marker to
  find the start of one: a stream that is one byte short of a frame shifts every sample
  that follows by a byte. The card plays that as white noise, and it plays the next
  track as white noise as well, because the program is the same one and nothing brings
  it back into step. A person who stops and starts again hears music, because a stop
  ends the program.

  A whole track ends on a frame, and three things cut one short:

  - A person presses next, and the pipeline of the track that they left is terminated
    in the middle of a buffer.
  - `PiFi.Player.PortDecoder` closes the port of `flac` a quarter of a second after
    its last answer, and that ends the program and takes the bytes that it had not
    written yet.
  - A file that a download left short ends where the bytes end.

  This element therefore writes whole frames and holds the rest for the next buffer.
  The end of a stream pads what is left with silence, so the count that reaches the
  port is always a whole number of frames. The pad is at most one frame, which is 23
  microseconds of a 44100 Hz stream.
  """

  use Membrane.Sink

  require Membrane.Logger

  alias Membrane.RawAudio
  alias PiFi.Output.APlayPort

  def_options(
    device: [
      spec: String.t(),
      default: "default",
      description: """
      The ALSA device, such as `rate48:CARD=Audio,DEV=0`. `PiFi.Output.Alsa`
      builds that name, and `rate48` of `/etc/asound.conf` converts the sample
      format and keeps the card at 48000 Hz. 44100 Hz is rough on this board,
      because USB audio needs a whole number of samples in each 1 ms packet.
      """
    ]
  )

  def_input_pad(:input, accepted_format: %RawAudio{}, flow_control: :auto)

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            device: String.t(),
            port: port() | nil,
            format: RawAudio.t() | nil,
            sounded?: boolean(),
            silent?: boolean(),
            part: binary(),
            role: APlayPort.role() | :only,
            registered?: boolean()
          }

    defstruct device: "default",
              port: nil,
              format: nil,
              sounded?: false,
              silent?: false,
              part: <<>>,
              role: :only,
              registered?: false
  end

  @impl true
  def handle_init(_ctx, options) do
    {[], %State{device: options.device}}
  end

  @impl true
  def handle_stream_format(:input, format, _ctx, %State{format: format} = state) do
    {[], state}
  end

  # A person stopped, so this element is the null sink now. Starting `aplay` again
  # for a new format would make sound after that.
  @impl true
  def handle_stream_format(:input, _format, _ctx, %State{silent?: true} = state) do
    {[], state}
  end

  @impl true
  def handle_stream_format(:input, format, _ctx, %State{} = state) do
    Membrane.Logger.info(
      "Playing #{format.sample_rate} Hz, #{format.channels} channels, " <>
        "#{format.sample_format} to #{state.device}"
    )

    case APlayPort.hold(program(), arguments(state, format)) do
      {:ok, port} ->
        {[], registered(%State{state | port: port, format: format})}

      {:error, reason} ->
        raise "Could not start aplay: #{inspect(reason)}"
    end
  end

  # The first buffer that reaches this sink is the moment that sound starts, and
  # this element is the only one that knows it. A source cannot say it: a stream
  # that never arrives, a playlist with no segment, and a decoder that gives
  # nothing all look the same from further up the pipeline.
  @impl true
  def handle_buffer(:input, buffer, _ctx, %State{port: port} = state) when is_port(port) do
    {whole, part} = frames(state.part <> buffer.payload, state.format)
    state = %State{state | part: part}

    case sent(state, whole) do
      {:ok, state} -> sounded(state, whole)
      {:faded, role, state} -> faded(role, state, whole)
      :closed -> stopped(state)
    end
  end

  # **This is the null sink.** No port means no sound, and the samples go nowhere. A
  # stop ends the program at once and the pipeline stops in its own time, so a person
  # hears silence as soon as they ask for it. See `PiFi.Player`.
  @impl true
  def handle_buffer(:input, _buffer, _ctx, %State{port: nil} = state) do
    {[], state}
  end

  # **The end of a track ends no program.** ALSA keeps about half a second of sound and
  # `PiFi.Output.APlayPort` keeps the card open, so that half second plays and the
  # pipeline of the next track writes to the same port. This element only stops writing.
  @impl true
  def handle_end_of_stream(:input, _ctx, %State{port: port} = state) when is_port(port) do
    _result = flush(state)
    ended(state)

    {[], quiet(state)}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %State{} = state) do
    {[], quiet(state)}
  end

  @doc """
  What `PiFi.Player` tells this element about the sound.

  `:silence` stops the sound now, and lets the pipeline stop later. `aplay` owns the
  sound card and it reads at the rate of the clock of the DAC, so ending the program is
  what makes the room quiet. `PiFi.Output.APlayPort.close/0` does that, and a
  measurement on 2026-08-21 gave 35 to 245 ms from a stop to silence.

  `:fade_out` and `:fade_in` name the two sides of a crossfade. From then on this
  element gives its samples to `PiFi.Output.APlayPort.blend/2` in the place of writing
  them to the port, and that process sums the two streams, because a sound card takes
  one.

  **The incoming sink has no format when it gets the notification**, because nothing has
  reached it yet, so it registers with the port at whichever of the two comes last. A
  fade that the port refuses leaves this element writing to the port as it always did,
  and a person hears the gap that they would have heard with the setting turned off.
  """
  @impl true
  def handle_parent_notification(:silence, _ctx, %State{port: nil} = state) do
    {[], %State{state | silent?: true}}
  end

  @impl true
  def handle_parent_notification(:silence, _ctx, %State{} = state) do
    APlayPort.close()

    {[], quiet(%State{state | port: nil, format: nil, silent?: true})}
  end

  @impl true
  def handle_parent_notification({:fade_out, milliseconds}, _ctx, %State{} = state) do
    # **The track that is ending is the one that opens the fade**, because it is the one
    # already writing to the port, and the port cannot fade without a program.
    case APlayPort.fade(milliseconds) do
      :ok -> answered(registered(%State{state | role: :outgoing, registered?: false}))
      {:error, _reason} -> answered(state)
    end
  end

  @impl true
  def handle_parent_notification(:fade_in, _ctx, %State{} = state) do
    {[], registered(%State{state | role: :incoming, registered?: false})}
  end

  @impl true
  def handle_parent_notification(_notification, _ctx, %State{} = state), do: {[], state}

  @impl true
  def handle_info(message, _ctx, state) do
    Membrane.Logger.debug("Ignoring #{inspect(message)}")
    {[], state}
  end

  # The port belongs to `PiFi.Output.APlayPort` and the next pipeline wants it, so
  # this ends nothing. A person who asked for silence already got it above.
  @impl true
  def handle_terminate_request(_ctx, %State{role: :only} = state) do
    {[terminate: :normal], %State{state | port: nil}}
  end

  # **A pipeline that stops in the middle of a fade takes one side of it with it.** The
  # other side would then wait in `blend/2` for frames that no process is going to send,
  # so the fade ends here and the track that is left plays on its own.
  @impl true
  def handle_terminate_request(_ctx, %State{} = state) do
    APlayPort.cancel_fade()

    {[terminate: :normal], quiet(state)}
  end

  @doc """
  The command line that one format needs.

  **`PiFi.Output.APlayPort` keeps one port for one of these**, so this list is the
  name of the sound as well as the way to make it: two tracks of one rate give the same
  list and one program, and a track of another rate gives another list and another
  program.
  """
  @spec arguments(State.t(), RawAudio.t()) :: [String.t()]
  def arguments(%State{} = state, format) do
    [
      "--device=#{state.device}",
      "--format=#{alsa_format(format.sample_format)}",
      "--rate=#{format.sample_rate}",
      "--channels=#{format.channels}",
      "--file-type=raw",
      "--quiet",
      "-"
    ]
  end

  # **`PiFi.Player` needs to know whether the fade took before it starts the second
  # pipeline.** A sink of another output ignores the notification above and answers
  # nothing, and a player that never hears `:ok` starts no second pipeline, so an output
  # that cannot fade plays one track at a time in the way that it always did.
  defp answered(%State{role: :outgoing} = state), do: {[notify_parent: {:fading, :ok}], state}
  defp answered(%State{} = state), do: {[notify_parent: {:fading, :error}], state}

  # The port needs the shape of the audio before it can sum two streams of it, and it
  # decides there whether the sum is possible at all.
  defp registered(%State{role: :only} = state), do: state
  defp registered(%State{registered?: true} = state), do: state
  defp registered(%State{format: nil} = state), do: state

  defp registered(%State{} = state) do
    case APlayPort.fading(state.role, state.format) do
      :ok ->
        %State{state | registered?: true}

      {:error, reason} ->
        Membrane.Logger.info("This track plays with no crossfade: #{inspect(reason)}")

        %State{state | role: :only, registered?: false}
    end
  end

  # Outside a fade this writes to the port itself, and the busy limits of that port are
  # what pace the pipeline. Inside one it hands the samples to the process that owns the
  # port, which waits for the other stream and sums the two.
  defp sent(%State{role: :only, port: port} = state, whole) do
    case write(port, whole) do
      :ok -> {:ok, state}
      :closed -> :closed
    end
  end

  defp sent(%State{role: role} = state, whole) do
    case APlayPort.blend(role, whole) do
      :ok -> {:ok, state}
      :finished -> {:faded, role, %State{state | role: :only, registered?: false}}
      :cancelled -> {:faded, :cancelled, %State{state | role: :only, registered?: false}}
      :closed -> :closed
    end
  end

  # **The fade is over, and what that means depends on how it ended.** A fade that ran
  # to its length leaves the track that was ending at no volume at all, so this element
  # takes its samples and drops them until `PiFi.Player` stops the pipeline. Every other
  # side of it is a track that is still playing, and it goes back to writing to the port.
  defp faded(:outgoing, %State{} = state, _whole) do
    {[notify_parent: :faded], %State{state | port: nil}}
  end

  defp faded(_role, %State{} = state, whole) do
    {actions, state} = sounded(state, whole)

    {actions ++ [notify_parent: :faded], state}
  end

  defp flush(%State{part: <<>>}), do: :ok

  defp flush(%State{role: :only, port: port} = state) do
    write(port, pad(state.part, state.format))
  end

  defp flush(%State{role: role} = state) do
    APlayPort.blend(role, pad(state.part, state.format))
  end

  # **A crossfade means that there was no gap**, so nothing measures one: the next track
  # was already playing when this one stopped.
  defp ended(%State{role: :only}), do: APlayPort.wrote_last()
  defp ended(%State{role: role}), do: APlayPort.fade_ended(role)

  defp quiet(%State{} = state) do
    %State{state | port: nil, part: <<>>, role: :only, registered?: false}
  end

  # The first write says that sound started, and a write of no bytes says nothing: a
  # buffer that holds less than one frame has made no sound yet.
  defp sounded(%State{sounded?: false} = state, whole) when whole != <<>> do
    # The port measures the silence between one track and the next, and this is the
    # moment that ends it. See `PiFi.Output.APlayPort.wrote_first/0`.
    APlayPort.wrote_first()

    {[notify_parent: :playing], %State{state | sounded?: true}}
  end

  defp sounded(state, _whole), do: {[], state}

  # **`aplay` reads frames, and this gives it whole ones.** A frame is one sample of
  # each channel, so a stream of 24 bits and two channels holds 6 bytes in each one.
  #
  # A format of `nil` cannot happen for a port that is open, because
  # `handle_stream_format/4` is what opens one, and this answers for it in any case:
  # the bytes go as they are.
  defp frames(bytes, nil), do: {bytes, <<>>}

  defp frames(bytes, format) do
    size = RawAudio.frame_size(format)
    whole = byte_size(bytes) - rem(byte_size(bytes), size)

    <<frames::binary-size(^whole), part::binary>> = bytes

    {frames, part}
  end

  # **Silence, and not the bytes of the next track.** A part of a frame reaches the
  # port as a whole one, so the stream stays in step, and 0 is silence for every
  # signed format that a decoder of this firmware gives.
  defp pad(part, nil), do: part

  defp pad(part, format) do
    missing = RawAudio.frame_size(format) - byte_size(part)

    part <> <<0::size(missing * 8)>>
  end

  # A test names another program with `:aplay_command`. Nothing sets it in production,
  # and the Nerves system gives `aplay`.
  defp program, do: Application.get_env(:pifi, :aplay_command, "aplay")

  # **A program that went takes its port with it, and a write to a port that is gone
  # raises.** `PiFi.Output.APlayPort` reads the exit of the program and keeps the
  # reason, so this element ends the pipeline and `PiFi.Player` starts the stream
  # again.
  defp write(port, payload) do
    Port.command(port, payload)

    :ok
  rescue
    ArgumentError -> :closed
  end

  defp stopped(%State{} = state) do
    Membrane.Logger.error("aplay is gone, so this pipeline ends.")

    {[terminate: :normal], quiet(%State{state | format: nil})}
  end

  @doc """
  The ALSA name of one sample format of Membrane.

  Membrane packs a 24-bit sample in 3 bytes, and that is `S24_3LE` for ALSA.
  `S24_LE` puts 24 bits in 4 bytes, so it is the wrong name here, and libmad gives
  24-bit samples for each MP3 stream. A wrong name here gives noise and not music,
  so a test covers each pair.
  """
  @spec alsa_format(Membrane.RawAudio.SampleFormat.t()) :: String.t()
  def alsa_format(:s8), do: "S8"
  def alsa_format(:u8), do: "U8"
  def alsa_format(:s16le), do: "S16_LE"
  def alsa_format(:s16be), do: "S16_BE"
  def alsa_format(:u16le), do: "U16_LE"
  def alsa_format(:u16be), do: "U16_BE"
  def alsa_format(:s24le), do: "S24_3LE"
  def alsa_format(:s24be), do: "S24_3BE"
  def alsa_format(:u24le), do: "U24_3LE"
  def alsa_format(:u24be), do: "U24_3BE"
  def alsa_format(:s32le), do: "S32_LE"
  def alsa_format(:s32be), do: "S32_BE"
  def alsa_format(:u32le), do: "U32_LE"
  def alsa_format(:u32be), do: "U32_BE"
  def alsa_format(:f32le), do: "FLOAT_LE"
  def alsa_format(:f32be), do: "FLOAT_BE"
  def alsa_format(:f64le), do: "FLOAT64_LE"
  def alsa_format(:f64be), do: "FLOAT64_BE"
end
