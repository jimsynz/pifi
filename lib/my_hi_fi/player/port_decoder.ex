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

  def_input_pad(:input, accepted_format: _any, flow_control: :auto)

  def_output_pad(:output, accepted_format: %RawAudio{}, flow_control: :auto)

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            command: String.t(),
            arguments: [String.t()],
            port: port() | nil,
            held: binary(),
            format: RawAudio.t() | nil
          }

    defstruct [:command, :arguments, :port, :format, held: <<>>]
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
    read(state.held <> bytes, state)
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, _ctx, %State{port: port} = state) do
    Membrane.Logger.error("#{state.command} stopped with status #{status}")
    {[end_of_stream: :output], %State{state | port: nil}}
  end

  @impl true
  def handle_info(message, _ctx, state) do
    Membrane.Logger.debug("Ignoring #{inspect(message)}")
    {[], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %State{} = state) do
    {[], close(state)}
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

  defp close(%State{port: nil} = state), do: state

  defp close(%State{port: port} = state) do
    if Port.info(port), do: Port.close(port)

    %State{state | port: nil}
  end
end
