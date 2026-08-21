defmodule MyHiFi.Output.APlaySink do
  @moduledoc """
  A Membrane sink that plays raw audio through `aplay`.

  The Nerves system holds `alsa-lib`, `aplay` and `amixer`, and no other audio
  software. `membrane_alsa_plugin` does not exist, so this sink starts `aplay` in
  an Erlang port and writes the samples to it.

  The port gives the pacing for free. `aplay` reads at the rate of the clock of
  the DAC, so a write blocks once its buffer is full, and the pipeline then runs
  at the speed of the hardware.

  `aplay` starts again when the stream format changes, because the format is on
  the command line and not in the stream.
  """

  use Membrane.Sink

  require Membrane.Logger

  alias Membrane.RawAudio

  def_options(
    device: [
      spec: String.t(),
      default: "default",
      description: """
      The ALSA device, such as `plughw:CARD=Audio,DEV=0`. A `plughw`
      device lets ALSA convert the format and the rate for a DAC that
      accepts neither.
      """
    ]
  )

  def_input_pad(:input, accepted_format: %RawAudio{}, flow_control: :auto)

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            device: String.t(),
            port: port() | nil,
            format: RawAudio.t() | nil
          }

    defstruct device: "default", port: nil, format: nil
  end

  @impl true
  def handle_init(_ctx, options) do
    {[], %State{device: options.device}}
  end

  @impl true
  def handle_stream_format(:input, format, _ctx, %State{format: format} = state) do
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

  @impl true
  def handle_buffer(:input, buffer, _ctx, %State{port: port} = state) when is_port(port) do
    Port.command(port, buffer.payload)
    {[], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %State{} = state) do
    {[], close_port(state)}
  end

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

    Port.open({:spawn_executable, aplay()}, [:binary, :exit_status, args: arguments])
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

  # Membrane packs a 24-bit sample in 3 bytes, and that is `S24_3LE` for ALSA.
  # `S24_LE` holds 24 bits in 4 bytes, so it is the wrong name here.
  defp alsa_format(:s8), do: "S8"
  defp alsa_format(:u8), do: "U8"
  defp alsa_format(:s16le), do: "S16_LE"
  defp alsa_format(:s16be), do: "S16_BE"
  defp alsa_format(:u16le), do: "U16_LE"
  defp alsa_format(:u16be), do: "U16_BE"
  defp alsa_format(:s24le), do: "S24_3LE"
  defp alsa_format(:s24be), do: "S24_3BE"
  defp alsa_format(:u24le), do: "U24_3LE"
  defp alsa_format(:u24be), do: "U24_3BE"
  defp alsa_format(:s32le), do: "S32_LE"
  defp alsa_format(:s32be), do: "S32_BE"
  defp alsa_format(:u32le), do: "U32_LE"
  defp alsa_format(:u32be), do: "U32_BE"
  defp alsa_format(:f32le), do: "FLOAT_LE"
  defp alsa_format(:f32be), do: "FLOAT_BE"
  defp alsa_format(:f64le), do: "FLOAT64_LE"
  defp alsa_format(:f64be), do: "FLOAT64_BE"
end
