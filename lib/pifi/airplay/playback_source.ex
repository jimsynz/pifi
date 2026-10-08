defmodule PiFi.AirPlay.PlaybackSource do
  @moduledoc """
  The audio of an AirPlay session, as something the player can play.

  This is the join between a telephone sending audio and the ordinary playing of it, so
  volume, the screens and the history all work as they do for anything else.

  ## Two kinds of session, and the kind decides what leaves here

  A telephone picks the kind, and `PiFi.AirPlay.Session` opens the socket to match.

    * A **realtime** session gives ALAC in RTP over UDP. `PiFi.AirPlay.Alac` decodes it
      here, because there is no ALAC decoder on Hex and the one in this repository is a
      NIF rather than a Membrane element. Raw samples leave.
    * A **buffered** session gives AAC over TCP, and this firmware already holds a
      decoder for AAC — the one every podcast and half the radio stations go through.
      So the frames leave as they arrived, in a `Membrane.RemoteStream`, and
      `PiFi.Player.Pipeline` hands them to `Membrane.AAC.FDK.Decoder`.

  The socket, the demand and the asking are the same for both, which is why one element
  serves them.

  ## The sound card is the clock, and nothing else may be

  The pad is `:manual`, so this produces only what has been asked for, and what asks is
  eventually `PiFi.Output.APlaySink` at the rate the card consumes. **Anything else is a
  second clock.** A source that pushed on a timer of its own would run a few parts per
  million away from the card and either starve it or outrun it, which is the drift that
  `snd-aloop` already taught this project on the Spotify work.

  When the socket has nothing yet this asks again shortly rather than blocking, because
  a demand that never returns stops the pipeline rather than waiting in it.

  ## A gap becomes silence, and that is a decision made here

  `PiFi.AirPlay.JitterBuffer` reports packets it has given up on rather than hiding
  them, precisely so that something can choose. This chooses silence: it is the answer
  that cannot make anything worse, where repeating the last frame can turn a dropout
  into a stutter that draws more attention than the hole did.

  **The length of the silence is the length of the audio that was lost**, so the stream
  stays in time with itself. A gap filled with nothing at all would pull everything
  after it earlier, and a sender's idea of where it is in the track would slowly stop
  matching what a person hears.

  ## The configuration is not negotiated

  A realtime sender sends no magic cookie, so `PiFi.AirPlay.Alac.config/1` supplies one.
  The frames per packet come from `SETUP` when a sender named them. A buffered session
  needs none of this: the ADTS header of each frame says what the frame is.
  """

  use Membrane.Source

  require Membrane.Logger

  alias Membrane.Buffer
  alias Membrane.RawAudio
  alias Membrane.RemoteStream
  alias PiFi.AirPlay.Alac
  alias PiFi.AirPlay.AudioSocket
  alias PiFi.AirPlay.BufferedSocket

  # A packet is about eight milliseconds of audio, so this is a little under one packet:
  # long enough not to spin, short enough that the card is never kept waiting by it.
  @quiet 5

  # **A stream that goes quiet says so once a second and not once an ask.** The counts
  # it carries are the ones that separate a telephone that stopped sending from one
  # whose packets arrive and will not open, and the second of those looks exactly like
  # the first from here.
  @rounds_before_reporting div(1000, @quiet)

  def_options(
    socket: [
      spec: pid(),
      description: "The `PiFi.AirPlay.AudioSocket` that is taking the audio."
    ],
    config: [
      spec: binary() | nil,
      default: nil,
      description: """
      The twenty-four byte ALAC configuration. It defaults to what a realtime AirPlay
      sender sends, which is the one a sender never gives. A buffered session reads
      none of it.
      """
    ],
    kind: [
      spec: :realtime | :buffered,
      default: :realtime,
      description: "Which kind of session the socket is taking."
    ]
  )

  # `demand_unit: :bytes` is not optional. Without it the pad takes the unit of whatever
  # it is linked to — `PiFi.Output.APlaySink` asks in buffers — and the `handle_demand/5`
  # clause below never matches, so the first demand crashes the pipeline. See
  # `PiFi.Player.FileSource` and `PiFi.Player.HttpSource`, which carry the same line.
  def_output_pad(:output,
    accepted_format: any_of(%RawAudio{}, %RemoteStream{}),
    flow_control: :manual,
    demand_unit: :bytes
  )

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            socket: pid(),
            kind: :realtime | :buffered,
            config: binary(),
            decoder: term(),
            format: RawAudio.t() | RemoteStream.t() | nil,
            silence: binary(),
            demand: non_neg_integer(),
            asking?: boolean(),
            quiet_rounds: non_neg_integer(),
            heard?: boolean()
          }

    defstruct [
      :socket,
      :config,
      :decoder,
      :format,
      kind: :realtime,
      silence: <<>>,
      demand: 0,
      asking?: false,
      quiet_rounds: 0,
      heard?: false
    ]
  end

  @doc false
  @impl true
  def handle_init(_ctx, options) do
    {[],
     %State{
       socket: options.socket,
       kind: options.kind,
       config: options.config || Alac.config()
     }}
  end

  # **A buffered session needs no decoder and no configuration.** The frames carry an
  # ADTS header that says what each one is, and `Membrane.AAC.FDK.Decoder` reads it.
  @doc false
  @impl true
  def handle_playing(_ctx, %State{kind: :buffered} = state) do
    format = %RemoteStream{content_format: nil, type: :bytestream}

    Membrane.Logger.info("Playing buffered AirPlay audio from #{inspect(state.socket)}.")

    {[stream_format: {:output, format}], %State{state | format: format}}
  end

  @doc false
  @impl true
  def handle_playing(_ctx, %State{} = state) do
    with {:ok, described} <- Alac.describe(state.config),
         {:ok, sample_format} <- Alac.sample_format(described.bit_depth),
         {:ok, decoder} <- Alac.start(state.config) do
      format = %RawAudio{
        channels: described.channels,
        sample_rate: described.sample_rate,
        sample_format: sample_format
      }

      state = %State{
        state
        | decoder: decoder,
          format: format,
          silence: :binary.copy(<<0>>, described.frame_length * RawAudio.frame_size(format))
      }

      Membrane.Logger.info(
        "Playing AirPlay audio from #{inspect(state.socket)}: " <>
          "#{described.channels} channels, #{described.sample_rate} Hz, " <>
          "#{described.bit_depth}-bit, #{described.frame_length} frames to a packet."
      )

      {[stream_format: {:output, format}], state}
    else
      {:error, reason} ->
        raise "This AirPlay stream cannot be decoded: #{inspect(reason)}."
    end
  end

  @doc false
  @impl true
  def handle_demand(:output, size, :bytes, _ctx, %State{} = state) do
    served(%State{state | demand: state.demand + size})
  end

  @doc false
  @impl true
  def handle_info(:take, _ctx, %State{} = state) do
    served(%State{state | asking?: false})
  end

  def handle_info(_message, _ctx, state), do: {[], state}

  defp served(%State{demand: demand} = state) when demand <= 0, do: {[], state}

  # **A buffered session loses no frame and conceals no gap.** The audio arrives on a
  # TCP connection, so it arrives in order or the session is over, and there is nothing
  # here to put right.
  defp served(%State{kind: :buffered} = state) do
    case BufferedSocket.take(state.socket) do
      :empty -> {[], asking(quiet(state))}
      {:ok, frame} -> sent(heard(state), frame.payload)
    end
  end

  defp served(%State{} = state) do
    case AudioSocket.take(state.socket) do
      :empty ->
        {[], asking(quiet(state))}

      {:gap, count} ->
        Membrane.Logger.debug("#{count} AirPlay packets did not arrive, so that much silence.")

        sent(heard(state), :binary.copy(state.silence, count))

      {:ok, packet} ->
        case Alac.decode(state.decoder, packet.payload) do
          {:ok, samples} ->
            sent(heard(state), samples)

          # A frame the decoder could not read is a gap of exactly its own length.
          {:error, reason} ->
            Membrane.Logger.debug("An AirPlay frame would not decode: #{inspect(reason)}")

            sent(heard(state), state.silence)
        end
    end
  end

  # **The first packet is worth a line of its own**, because everything before it is a
  # handshake that can look right and carry nothing.
  defp heard(%State{heard?: true} = state), do: %State{state | quiet_rounds: 0}

  defp heard(%State{} = state) do
    Membrane.Logger.info("The first AirPlay audio of this session arrived.")

    %State{state | heard?: true, quiet_rounds: 0}
  end

  defp quiet(%State{quiet_rounds: rounds} = state)
       when rounds < @rounds_before_reporting do
    %State{state | quiet_rounds: rounds + 1}
  end

  defp quiet(%State{} = state) do
    Membrane.Logger.debug(
      "A second of no AirPlay audio. The socket has #{inspect(statistics(state))}."
    )

    %State{state | quiet_rounds: 0}
  end

  # A socket that has gone cannot say what it saw, and the asking must not be what
  # raises. `PiFi.AirPlay.Monitor` logs the reason it went.
  defp statistics(%State{kind: :buffered, socket: socket}), do: counted(socket, BufferedSocket)
  defp statistics(%State{socket: socket}), do: counted(socket, AudioSocket)

  defp counted(socket, module) do
    module.statistics(socket)
  catch
    :exit, reason -> reason
  end

  defp sent(%State{} = state, <<>>), do: served(state)

  defp sent(%State{} = state, samples) do
    state = %State{state | demand: max(state.demand - byte_size(samples), 0)}

    {actions, state} = served(state)

    {[buffer: {:output, %Buffer{payload: samples}}] ++ actions, state}
  end

  # One timer at a time. A demand that arrives while this is already waiting must not
  # start a second, or the asking doubles every time the socket runs dry.
  defp asking(%State{asking?: true} = state), do: state

  defp asking(%State{} = state) do
    Process.send_after(self(), :take, @quiet)

    %State{state | asking?: true}
  end
end
