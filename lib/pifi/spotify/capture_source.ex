defmodule PiFi.Spotify.CaptureSource do
  @moduledoc """
  Reads the capture side of the ALSA loopback, so a cast is a stream like any other.

  librespot plays into `hw:Loopback,0,0` and this reads `hw:Loopback,1,0` through
  `arecord`, in the way that `PiFi.Player.PortDecoder` reads a decoder and
  `PiFi.Output.APlaySink` writes to `aplay`. The samples then go to the sink that every
  other stream goes to, so `aplay` stays the one program that opens the sound card.

  ## It reads raw and not WAV

  `PiFi.Player.PortDecoder` parses a WAV header because it cannot know what a decoder
  will give it. This can: `arecord` is told the rate, the channel count and the width
  on its own command line, so `-t raw` gives the samples with nothing in front of them
  and the format is a fact rather than a discovery.

  **44100 Hz is not converted here.** `rate48` of `/etc/asound.conf` holds the USB card
  at 48000 Hz and converts for it, which is the arrangement the whole player already
  relies on, so this element needs no resampler. See `PiFi.Output.Alsa`.

  ## It pushes, because a microphone does not wait

  A capture runs at the rate of its clock whether anything reads it or not, so the pad
  is `:push`. That is also the one weakness of the loopback: `snd-aloop` runs off a
  timer and the DAC runs off its own crystal, and a few parts per million apart will
  accumulate. See `PiFi.Spotify.Loopback`.

  ## Nothing starts it but a sink event

  **The capture side hands over full-rate silence while nothing plays**, which a board
  confirmed. So this element must not run except between librespot opening its sink and
  closing it: an element started on data would never stop, and it would hold the card
  against the player for ever.
  """

  use Membrane.Source

  require Membrane.Logger

  alias Membrane.Buffer
  alias Membrane.RawAudio
  alias PiFi.Spotify.Loopback

  @arecord "arecord"

  # What librespot writes into the loopback, and therefore what comes out of it.
  @sample_rate 44_100
  @channels 2
  @sample_format :s16le

  def_options(
    device: [
      spec: String.t(),
      default: nil,
      description: """
      The ALSA name to capture. It defaults to the capture half of the loopback, and a
      test names something of its own.
      """
    ],
    command: [
      spec: String.t(),
      default: @arecord,
      description: "The program that captures. A test names one that is not `arecord`."
    ]
  )

  def_output_pad(:output, accepted_format: %RawAudio{}, flow_control: :push)

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{device: String.t(), command: String.t(), port: port() | nil}

    defstruct [:device, :command, :port]
  end

  @impl true
  def handle_init(_ctx, options) do
    {[],
     %State{
       device: options.device || Loopback.capture_device(),
       command: options.command
     }}
  end

  @impl true
  def handle_playing(_ctx, %State{} = state) do
    format = %RawAudio{
      channels: @channels,
      sample_rate: @sample_rate,
      sample_format: @sample_format
    }

    {[stream_format: {:output, format}], %State{state | port: open(state)}}
  end

  @impl true
  def handle_info({port, {:data, bytes}}, _ctx, %State{port: port} = state) do
    {[buffer: {:output, %Buffer{payload: bytes}}], state}
  end

  # **`arecord` leaving is the end of the stream and not a fault of the pipeline.** A
  # cast that ended takes the program with it, and a pipeline that raised there would
  # report an error for something a person did on purpose.
  @impl true
  def handle_info({port, {:exit_status, status}}, _ctx, %State{port: port} = state) do
    if status != 0 do
      Membrane.Logger.warning("#{state.command} stopped with status #{status}")
    end

    {[end_of_stream: :output], %State{state | port: nil}}
  end

  @impl true
  def handle_info(message, _ctx, state) do
    Membrane.Logger.debug("Ignoring #{inspect(message)}")

    {[], state}
  end

  @impl true
  def handle_terminate_request(_ctx, %State{} = state) do
    {[terminate: :normal], close(state)}
  end

  @doc """
  The arguments that `arecord` is given.

  It is public so a test can read them without starting anything.

      iex> PiFi.Spotify.CaptureSource.argv("hw:Loopback,1,0")
      ["-D", "hw:Loopback,1,0", "-f", "S16_LE", "-r", "44100", "-c", "2", "-t", "raw"]
  """
  @spec argv(String.t()) :: [String.t()]
  def argv(device) do
    [
      "-D",
      device,
      "-f",
      "S16_LE",
      "-r",
      to_string(@sample_rate),
      "-c",
      to_string(@channels),
      "-t",
      "raw"
    ]
  end

  defp open(%State{} = state) do
    program =
      System.find_executable(state.command) ||
        raise """
        #{state.command} is not on the PATH.

        It comes with `aplay`, which this firmware already carries, so a build that has
        one and not the other has lost something it did not mean to.
        """

    Port.open({:spawn_executable, program}, [
      :binary,
      :exit_status,
      args: argv(state.device)
    ])
  end

  defp close(%State{port: nil} = state), do: state

  defp close(%State{port: port} = state) do
    Port.close(port)

    %State{state | port: nil}
  rescue
    ArgumentError -> %State{state | port: nil}
  end
end
