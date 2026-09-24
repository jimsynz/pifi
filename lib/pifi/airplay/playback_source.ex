defmodule PiFi.AirPlay.PlaybackSource do
  @moduledoc """
  The audio of an AirPlay session, as something the player can play.

  It takes packets from a `PiFi.AirPlay.AudioSocket`, decodes them with
  `PiFi.AirPlay.Alac`, and gives raw samples to the rest of the pipeline. This is the
  join between a telephone sending audio and the ordinary playing of it, so volume, the
  screens and the history all work as they do for anything else.

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
  The frames per packet come from `SETUP` when a sender named them.
  """

  use Membrane.Source

  require Membrane.Logger

  alias Membrane.Buffer
  alias Membrane.RawAudio
  alias PiFi.AirPlay.Alac
  alias PiFi.AirPlay.AudioSocket

  # A packet is about eight milliseconds of audio, so this is a little under one packet:
  # long enough not to spin, short enough that the card is never kept waiting by it.
  @quiet 5

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
      sender sends, which is the one a sender never gives.
      """
    ]
  )

  def_output_pad(:output, accepted_format: %RawAudio{}, flow_control: :manual)

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            socket: pid(),
            config: binary(),
            decoder: term(),
            format: RawAudio.t() | nil,
            silence: binary(),
            demand: non_neg_integer(),
            asking?: boolean()
          }

    defstruct [:socket, :config, :decoder, :format, silence: <<>>, demand: 0, asking?: false]
  end

  @doc false
  @impl true
  def handle_init(_ctx, options) do
    {[], %State{socket: options.socket, config: options.config || Alac.config()}}
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

  defp served(%State{} = state) do
    case AudioSocket.take(state.socket) do
      :empty ->
        {[], asking(state)}

      {:gap, count} ->
        Membrane.Logger.debug("#{count} AirPlay packets did not arrive, so that much silence.")

        sent(state, :binary.copy(state.silence, count))

      {:ok, packet} ->
        case Alac.decode(state.decoder, packet.payload) do
          {:ok, samples} -> sent(state, samples)
          # A frame the decoder could not read is a gap of exactly its own length.
          {:error, _reason} -> sent(state, state.silence)
        end
    end
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
