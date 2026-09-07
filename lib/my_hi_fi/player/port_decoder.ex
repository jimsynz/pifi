defmodule MyHiFi.Player.PortDecoder do
  @moduledoc """
  Decodes audio with a program instead of a NIF.

  `MyHiFi.Output.APlaySink` already drives `aplay` through an Erlang port, and
  that pattern works on this board. This element uses it for a decoder: it writes
  the compressed bytes to the standard input of a program, and it reads the samples
  from the standard output.

  Two codecs need this, and Membrane holds a decoder for neither.

  - **Ogg Vorbis**, with `oggdec` from vorbis-tools. Hex holds no Vorbis package at
    all.
  - **Ogg FLAC**, with `flac --decode --ogg`. `membrane_flac_plugin` is a parser,
    and it decodes nothing.

  A program needs no NIF, no Bundlex target variables, and no precompiled archive.
  It also reads the Ogg container itself, and `membrane_ogg_plugin` depayloads Ogg
  into an Opus stream only.

  ## The WAV header

  Both programs write a WAV header before the samples, and that header names the
  rate, the channel count, and the width of a sample. This element reads it, tells
  the pipeline, and then forwards the samples.

  It reads the length of the data from nothing: a live stream has no length, and
  the two programs disagree about what to write there. `oggdec` writes
  `0x7FFFFFD3`, and `flac` writes 0 and warns. Everything after the `data` marker
  is audio.

  ## What limits the rate

  The program gives samples only as fast as it gets bytes, and the bytes come
  through the input pad of this element. The chain is therefore limited by the
  network, and no queue here can grow without a limit.

  ## The end of a track, and the half close that Erlang does not hold

  **The end of the input must reach the output, or the track never ends.** This
  element closed the port and sent nothing when its input ended, so the sink kept its
  card open, `aplay` played the queue and then silence, and
  `MyHiFi.Player.Pipeline.handle_element_end_of_stream/4` never told the player to
  play the next track. A device on 2026-09-07 held a FLAC track of 3:44 at 5:32 and
  counted on. Every Jellyfin track of FLAC or of Ogg reached that state, and MP3 and
  AAC never did, because Membrane holds a decoder for those two and it forwards the
  end of a stream itself.

  **The program cannot be told that its input ended.** A measurement on the device on
  2026-09-07 fed a whole FLAC file to `flac --decode --stdout --silent -` and held the
  pipe open for 20 seconds after the last byte: the program waited all 20 seconds and
  then exited. So it ends when its standard input ends, and not at the end of the
  stream that it reads. Erlang holds no half close for a port, and
  `Port.close/1` ends the program and takes the output that it has not written yet.
  The `exit_status` clause below therefore never answers a track that reached its end.

  **This waits for the output to go quiet instead.** The end of the input starts a
  timer of a quarter of a second, each answer of the program starts it again, and the
  timer then closes the port and sends the end of the stream. A program that holds
  nothing more gives nothing more, so this loses no sample that a person could hear.
  The wait costs no time that a person waits either: the sink is playing the audio
  that this element already gave it, and the end of the stream travels behind that
  audio in the same queue.
  """

  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.RawAudio

  def_options(
    command: [
      spec: String.t(),
      description: "The name of the program, such as `oggdec`."
    ],
    arguments: [
      spec: [String.t()],
      description: "The arguments of the program. It must read standard input."
    ]
  )

  # **How long the program may be quiet before this element says that the track ended.**
  # The programs of this firmware decode far faster than the sound plays: a FLAC file of
  # 24 MB decoded in under a second on the board, so the output is quiet by the time
  # that the input ends. A quarter of a second is therefore generous, and it is behind
  # the audio of the sink in any case.
  @flush_ms 250

  def_input_pad(:input, accepted_format: _any, flow_control: :auto)

  def_output_pad(:output, accepted_format: %RawAudio{}, flow_control: :auto)

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            command: String.t(),
            arguments: [String.t()],
            port: port() | nil,
            held: binary(),
            format: RawAudio.t() | nil,
            flush_timer: reference() | nil,
            ending?: boolean()
          }

    defstruct [
      :command,
      :arguments,
      :port,
      :format,
      :flush_timer,
      held: <<>>,
      ending?: false
    ]
  end

  @impl true
  def handle_init(_ctx, options) do
    {[], %State{command: options.command, arguments: options.arguments}}
  end

  @impl true
  def handle_playing(_ctx, %State{} = state) do
    {[], %State{state | port: open(state)}}
  end

  # The format of the input says nothing about the samples, and the default
  # implementation of a filter forwards it. The output pad takes `RawAudio` only,
  # so that forward stops the pipeline. This element names its own format when it
  # reads the WAV header of the program.
  @impl true
  def handle_stream_format(:input, _format, _ctx, state), do: {[], state}

  @impl true
  def handle_buffer(:input, buffer, _ctx, %State{port: port} = state) when is_port(port) do
    Port.command(port, buffer.payload)
    {[], state}
  end

  @impl true
  def handle_buffer(:input, _buffer, _ctx, state), do: {[], state}

  # The samples of the program arrive here. The header comes first, and the audio
  # after it.
  @impl true
  def handle_info({port, {:data, bytes}}, _ctx, %State{port: port} = state) do
    {actions, state} = read(state.held <> bytes, state)

    {actions, waiting(state)}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, _ctx, %State{port: port} = state) do
    Membrane.Logger.error("#{state.command} stopped with status #{status}")
    {[end_of_stream: :output], %State{state | port: nil}}
  end

  # The program gave nothing for `@flush_ms`, so it holds nothing more and the track
  # reached its end. See the module documentation for why this cannot wait for the
  # program to exit.
  @impl true
  def handle_info(:flush, _ctx, %State{} = state) do
    {[end_of_stream: :output], close(state)}
  end

  @impl true
  def handle_info(message, _ctx, state) do
    Membrane.Logger.debug("Ignoring #{inspect(message)}")
    {[], state}
  end

  # A port that is already closed holds nothing to wait for.
  @impl true
  def handle_end_of_stream(:input, _ctx, %State{port: nil} = state) do
    {[end_of_stream: :output], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %State{} = state) do
    {[], waiting(%State{state | ending?: true})}
  end

  @impl true
  def handle_terminate_request(_ctx, %State{} = state) do
    {[terminate: :normal], close(state)}
  end

  defp read(bytes, %State{format: nil} = state) do
    case header(bytes) do
      {:ok, format, audio} ->
        Membrane.Logger.info(
          "#{state.command} gives #{format.sample_rate} Hz, #{format.channels} channels, " <>
            "#{format.sample_format}"
        )

        {actions, state} = read(audio, %State{state | format: format, held: <<>>})

        {[stream_format: {:output, format}] ++ actions, state}

      :more ->
        {[], %State{state | held: bytes}}
    end
  end

  defp read(<<>>, %State{} = state), do: {[], state}

  defp read(audio, %State{} = state) do
    {[buffer: {:output, %Membrane.Buffer{payload: audio}}], %State{state | held: <<>>}}
  end

  # A WAV file holds chunks. This reads the `fmt ` chunk for the shape of a sample,
  # and it then finds the `data` marker. It ignores the length that `data` names,
  # because a live stream has no length.
  defp header(<<"RIFF", _size::binary-size(4), "WAVE", rest::binary>>), do: chunks(rest, nil)
  defp header(bytes) when byte_size(bytes) < 12, do: :more
  defp header(_bytes), do: :more

  defp chunks(<<"data", _size::binary-size(4), audio::binary>>, format) when not is_nil(format) do
    {:ok, format, audio}
  end

  defp chunks(<<"fmt ", size::little-32, rest::binary>>, _format) when byte_size(rest) >= size do
    <<chunk::binary-size(^size), more::binary>> = rest

    chunks(more, format(chunk))
  end

  defp chunks(<<_name::binary-size(4), size::little-32, rest::binary>>, format)
       when byte_size(rest) >= size do
    <<_skipped::binary-size(^size), more::binary>> = rest

    chunks(more, format)
  end

  defp chunks(_bytes, _format), do: :more

  defp format(
         <<_audio_format::little-16, channels::little-16, sample_rate::little-32,
           _byte_rate::little-32, _block_align::little-16, bits::little-16, _rest::binary>>
       ) do
    %RawAudio{
      channels: channels,
      sample_rate: sample_rate,
      sample_format: sample_format(bits)
    }
  end

  # A WAV file holds a signed sample of 16 bits or more, and an unsigned one of 8.
  defp sample_format(8), do: :u8
  defp sample_format(16), do: :s16le
  defp sample_format(24), do: :s24le
  defp sample_format(32), do: :s32le

  defp open(%State{} = state) do
    program =
      System.find_executable(state.command) ||
        raise """
        #{state.command} is not on the PATH.

        The Nerves system holds no decoder for Ogg. NBPR gives the program, and it
        ships a binary and no header file, which is all that a port needs. See
        <https://github.com/jimsynz/nbpr>.
        """

    Port.open({:spawn_executable, program}, [:binary, :exit_status, args: state.arguments])
  end

  # The timer runs while the input has ended and not before it, so a track that plays
  # sets none of these.
  defp waiting(%State{ending?: false} = state), do: state

  defp waiting(%State{} = state) do
    if state.flush_timer, do: Process.cancel_timer(state.flush_timer)

    %State{state | flush_timer: Process.send_after(self(), :flush, @flush_ms)}
  end

  defp close(%State{port: nil} = state), do: state

  defp close(%State{port: port} = state) do
    if Port.info(port), do: Port.close(port)

    %State{state | port: nil, flush_timer: nil}
  end
end
