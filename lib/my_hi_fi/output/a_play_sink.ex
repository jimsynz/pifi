defmodule MyHiFi.Output.APlaySink do
  @moduledoc """
  A Membrane sink that plays raw audio through `aplay`.

  The Nerves system holds `alsa-lib`, `aplay` and `amixer`, and no other audio
  software. `membrane_alsa_plugin` does not exist, so this sink starts `aplay` in
  an Erlang port and writes the samples to it.

  `busy_limits_port` is what gives the pacing. `aplay` reads at the rate of the
  clock of the DAC, and with that option `Port.command/2` blocks this element once
  the queue of the port holds `@busy_limits` bytes. The demand of Membrane then
  stops reaching the decoder, and the whole pipeline runs at the speed of the
  hardware.

  **Without the option the queue of a port has no limit.** `Port.command/2` never
  blocks, so nothing pushed back and the pipeline ran ahead of the sound. A read on
  2026-08-24 measured the reader of the file 31 seconds in front of what a person
  heard, which put a resume 31 seconds past the place that they stopped at. A live
  stream hid this, because the network paced it instead.

  `aplay` starts again when the stream format changes, because the format is on
  the command line and not in the stream.
  """

  use Membrane.Sink

  require Membrane.Logger

  alias Membrane.RawAudio

  # How many bytes of samples may wait in the queue of the port. `Port.command/2`
  # blocks above the high mark and it runs again below the low one, so this is the
  # lead that the pipeline may hold over the sound. 44100 Hz of `s24le` stereo is
  # 264,600 bytes each second, so 128 KB is under half a second and 32 KB is about a
  # tenth of one.
  #
  # This is what makes `position_bytes` of an episode name the place that a person
  # heard. See the module documentation.
  @busy_limits {32 * 1024, 128 * 1024}

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

    {[], %State{state | port: start_aplay(state, format), format: format}}
  end

  # The first buffer that reaches this sink is the moment that sound starts, and
  # this element is the only one that knows it. A source cannot say it: a stream
  # that never arrives, a playlist with no segment, and a decoder that gives
  # nothing all look the same from further up the pipeline.
  @impl true
  def handle_buffer(:input, buffer, _ctx, %State{port: port, sounded?: false} = state)
      when is_port(port) do
    Port.command(port, buffer.payload)
    {[notify_parent: :playing], %State{state | sounded?: true}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, %State{port: port} = state) when is_port(port) do
    Port.command(port, buffer.payload)
    {[], state}
  end

  # **This is the null sink.** No port means no sound, and the samples go nowhere.
  # A stop closes the port at once and the pipeline stops in its own time, so a
  # person hears silence as soon as they ask for it. See `MyHiFi.Player`.
  @impl true
  def handle_buffer(:input, _buffer, _ctx, %State{port: nil} = state) do
    {[], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %State{} = state) do
    {[], close_port(state)}
  end

  @doc """
  Stop the sound now, and let the pipeline stop later.

  `aplay` holds the sound card and it reads at the rate of the clock of the DAC, so
  closing the port is what makes the room quiet. A measurement on 2026-08-21 gave 35
  to 245 ms from a stop to silence.
  """
  @impl true
  def handle_parent_notification(:silence, _ctx, %State{} = state) do
    {[], %State{close_port(state) | silent?: true}}
  end

  @impl true
  def handle_parent_notification(_notification, _ctx, %State{} = state), do: {[], state}

  @impl true
  def handle_info({port, {:exit_status, status}}, _ctx, %State{port: port} = state) do
    Membrane.Logger.error("aplay stopped with status #{status}")
    {[terminate: :normal], %State{state | port: nil}}
  end

  @impl true
  def handle_info(message, _ctx, state) do
    Membrane.Logger.debug("Ignoring #{inspect(message)}")
    {[], state}
  end

  @impl true
  def handle_terminate_request(_ctx, %State{} = state) do
    {[terminate: :normal], close_port(state)}
  end

  defp start_aplay(%State{} = state, format) do
    state = close_port(state)

    arguments = [
      "--device=#{state.device}",
      "--format=#{alsa_format(format.sample_format)}",
      "--rate=#{format.sample_rate}",
      "--channels=#{format.channels}",
      "--file-type=raw",
      "--quiet",
      "-"
    ]

    Port.open({:spawn_executable, aplay()}, [
      :binary,
      :exit_status,
      {:busy_limits_port, @busy_limits},
      args: arguments
    ])
  end

  defp close_port(%State{port: nil} = state), do: state

  defp close_port(%State{port: port} = state) do
    # Closing the port alone is not enough. `aplay` then sees the end of its
    # input, and it plays what it already holds before it stops. ALSA holds about
    # half a second, and the pipeline sends more while it shuts down, so a person
    # who presses stop waits several seconds for silence.
    #
    # Ending the program stops the sound at once. A person who wants to stop wants
    # to stop.
    stop_aplay(port)

    if Port.info(port), do: Port.close(port)

    %State{state | port: nil, format: nil}
  end

  defp stop_aplay(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", ["-TERM", to_string(os_pid)])
      nil -> :ok
    end
  end

  defp aplay do
    System.find_executable("aplay") ||
      raise "aplay is not on the PATH. The Nerves system gives it, and a host needs alsa-utils."
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
