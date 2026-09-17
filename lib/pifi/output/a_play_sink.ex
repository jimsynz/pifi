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
            part: binary()
          }

    defstruct device: "default",
              port: nil,
              format: nil,
              sounded?: false,
              silent?: false,
              part: <<>>
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
        {[], %State{state | port: port, format: format}}

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

    case write(port, whole) do
      :ok -> sounded(%State{state | part: part}, whole)
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
  def handle_end_of_stream(:input, _ctx, %State{port: port, part: part} = state)
      when is_port(port) and part != <<>> do
    _result = write(port, pad(part, state.format))
    APlayPort.wrote_last()

    {[], %State{state | port: nil, part: <<>>}}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %State{port: port} = state) when is_port(port) do
    APlayPort.wrote_last()

    {[], %State{state | port: nil, part: <<>>}}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %State{} = state) do
    {[], %State{state | port: nil, part: <<>>}}
  end

  @doc """
  Stop the sound now, and let the pipeline stop later.

  `aplay` owns the sound card and it reads at the rate of the clock of the DAC, so
  ending the program is what makes the room quiet. `PiFi.Output.APlayPort.close/0`
  does that, and a measurement on 2026-08-21 gave 35 to 245 ms from a stop to silence.
  """
  @impl true
  def handle_parent_notification(:silence, _ctx, %State{port: nil} = state) do
    {[], %State{state | silent?: true}}
  end

  @impl true
  def handle_parent_notification(:silence, _ctx, %State{} = state) do
    APlayPort.close()

    {[], %State{state | port: nil, format: nil, silent?: true, part: <<>>}}
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
  def handle_terminate_request(_ctx, %State{} = state) do
    {[terminate: :normal], %State{state | port: nil}}
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

    {[terminate: :normal], %State{state | port: nil, format: nil}}
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
