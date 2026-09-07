defmodule MyHiFi.Output.APlaySink do
  @moduledoc """
  A Membrane sink that plays raw audio through `aplay`.

  The Nerves system holds `alsa-lib`, `aplay` and `amixer`, and no other audio
  software. `membrane_alsa_plugin` does not exist, so this sink writes the samples to
  `aplay` through an Erlang port.

  `busy_limits_port` is what gives the pacing. `aplay` reads at the rate of the clock
  of the DAC, and with that option `Port.command/2` blocks this element once the queue
  of the port is full. The demand of Membrane then stops reaching the decoder, and the
  whole pipeline runs at the speed of the hardware.
  `MyHiFi.Output.APlayPort` holds the limits and the measurement that decided them.

  `aplay` starts again when the stream format changes, because the format is on
  the command line and not in the stream.

  ## The program outlives this element

  **`MyHiFi.Output.APlayPort` owns the port, and this element borrows it.** A start of
  `aplay` opens the sound card and holds a silence of about one second, so a program of
  its own for each pipeline gave a person a gap between one track and the next, and it
  cut the half second that ALSA still held at the end of every track.

  This element therefore asks that process for the program that its format needs,
  writes the samples to what it gets, and **writes nothing more when its input ends**.
  The card stays open, the queue plays out, and the next pipeline writes to the same
  port. A person who stops, pauses or asks for standby gets `:silence`, and that ends
  the program at once.

  A process that does not own a port may write to it, and the busy limits of that
  process still suspend whoever writes, so the pacing above is unchanged.
  """

  use Membrane.Sink

  require Membrane.Logger

  alias Membrane.RawAudio
  alias MyHiFi.Output.APlayPort

  def_options(
    device: [
      spec: String.t(),
      default: "default",
      description: """
      The ALSA device, such as `rate48:CARD=Audio,DEV=0`. `MyHiFi.Output.Alsa`
      builds that name, and `rate48` of `/etc/asound.conf` converts the sample
      format and holds the card at 48000 Hz. 44100 Hz is rough on this board,
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
            silent?: boolean()
          }

    defstruct device: "default", port: nil, format: nil, sounded?: false, silent?: false
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
  def handle_buffer(:input, buffer, _ctx, %State{port: port, sounded?: false} = state)
      when is_port(port) do
    case write(port, buffer.payload) do
      :ok -> {[notify_parent: :playing], %State{state | sounded?: true}}
      :closed -> stopped(state)
    end
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, %State{port: port} = state) when is_port(port) do
    case write(port, buffer.payload) do
      :ok -> {[], state}
      :closed -> stopped(state)
    end
  end

  # **This is the null sink.** No port means no sound, and the samples go nowhere. A
  # stop ends the program at once and the pipeline stops in its own time, so a person
  # hears silence as soon as they ask for it. See `MyHiFi.Player`.
  @impl true
  def handle_buffer(:input, _buffer, _ctx, %State{port: nil} = state) do
    {[], state}
  end

  # **The end of a track ends no program.** ALSA holds about half a second of sound and
  # `MyHiFi.Output.APlayPort` keeps the card open, so that half second plays and the
  # pipeline of the next track writes to the same port. This element only stops writing.
  @impl true
  def handle_end_of_stream(:input, _ctx, %State{} = state) do
    {[], %State{state | port: nil}}
  end

  @doc """
  Stop the sound now, and let the pipeline stop later.

  `aplay` holds the sound card and it reads at the rate of the clock of the DAC, so
  ending the program is what makes the room quiet. `MyHiFi.Output.APlayPort.close/0`
  does that, and a measurement on 2026-08-21 gave 35 to 245 ms from a stop to silence.
  """
  @impl true
  def handle_parent_notification(:silence, _ctx, %State{port: nil} = state) do
    {[], %State{state | silent?: true}}
  end

  @impl true
  def handle_parent_notification(:silence, _ctx, %State{} = state) do
    APlayPort.close()

    {[], %State{state | port: nil, format: nil, silent?: true}}
  end

  @impl true
  def handle_parent_notification(_notification, _ctx, %State{} = state), do: {[], state}

  @impl true
  def handle_info(message, _ctx, state) do
    Membrane.Logger.debug("Ignoring #{inspect(message)}")
    {[], state}
  end

  # The port belongs to `MyHiFi.Output.APlayPort` and the next pipeline wants it, so
  # this ends nothing. A person who asked for silence already got it above.
  @impl true
  def handle_terminate_request(_ctx, %State{} = state) do
    {[terminate: :normal], %State{state | port: nil}}
  end

  @doc """
  The command line that one format needs.

  **`MyHiFi.Output.APlayPort` holds one port for one of these**, so this list is the
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

  # A test names another program with `:aplay_command`. Nothing sets it in production,
  # and the Nerves system gives `aplay`.
  defp program, do: Application.get_env(:my_hi_fi, :aplay_command, "aplay")

  # **A program that went takes its port with it, and a write to a port that is gone
  # raises.** `MyHiFi.Output.APlayPort` reads the exit of the program and holds the
  # reason, so this element ends the pipeline and `MyHiFi.Player` starts the stream
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
  `S24_LE` holds 24 bits in 4 bytes, so it is the wrong name here, and libmad gives
  24-bit samples for each MP3 stream. A wrong name here gives noise and not music,
  so a test holds each pair.
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
