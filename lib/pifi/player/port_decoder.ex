defmodule PiFi.Player.PortDecoder do
  @moduledoc """
  Decodes audio with a program instead of a NIF.

  `PiFi.Output.APlaySink` already drives `aplay` through an Erlang port, and
  that pattern works on this board. This element uses it for a decoder: it writes
  the compressed bytes to the standard input of a program, and it reads the samples
  from the standard output.

  Two codecs need this, and Membrane has a decoder for neither.

  - **Ogg Vorbis**, with `oggdec` from vorbis-tools. Hex has no Vorbis package at
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

  **Demand gates nothing that arrives in `handle_info/3`.** The port driver reads
  what the program writes into the mailbox of this element whatever the element is
  doing, so the program never blocks on its output. This element used to send each
  `{:data, bytes}` on as a buffer, which ignored the demand of its output, and its
  input took Membrane's default auto demand of 600 KB. The sink is suspended in
  `Port.command/2` most of the time, so those buffers queued in its mailbox ahead of
  `:silence`. A measurement on the host on 2026-11-01, with a `dd` loop reading at
  CD rate in place of `aplay`, found 1.9 to 8.4 s of FLAC and 27.6 s of Vorbis in
  that mailbox, and a stop took as long.

  Both pads are therefore manual.

  - **The output sends only what the sink asks for, in buffers of `@buffer_ms`.**
    The samples wait in `held` until then. The size matters as much as the demand:
    the sink counts its queue in buffers, and one write of `flac` is 16 to 20 KB,
    which is about 100 ms. The same measurement then found at most 175 ms in the
    mailbox of the sink, and a stop took 0.4 s, which is what MP3 takes.
  - **The input asks for `@input_bytes` at a time while `held` is under
    `@held_ms`.** The program answers only for the bytes that it gets, so this is
    the one place that bounds its output. `PiFi.Player.Pipeline` keeps the queue in
    front of this pad small as well.

  `busy_limits_port` on the port of the program, with the pads left on `:auto`, would
  not do this. The program never blocks on its output, so it reads its input as fast
  as it decodes, the pipe never fills, and the queue of the port never reaches a
  limit. The auto output would still send every answer to the sink.

  **What the program has read and not yet answered is not counted.** The program
  answers well behind its input: a trace showed `oggdec` give several seconds of
  samples for a few writes that all went in while `held` was under the bound. A count
  of the bytes written since the last answer doesn't measure that, because the
  program keeps answering for earlier input. A cap on that count also stopped 24-bit
  FLAC and Vorbis before their first answer, because each needs more than 16 KB before
  it writes a header. `held` therefore reached 1.6 s of FLAC and 6 s of Vorbis in the
  measurement. That costs memory and the lead of a resume. It doesn't cost the time of
  a stop, which depends on the mailbox of the sink alone.

  ## The end of a track, and the half close that Erlang does not hold

  **The end of the input must reach the output, or the track never ends.** This
  element closed the port and sent nothing when its input ended, so the sink kept its
  card open, `aplay` played the queue and then silence, and
  `PiFi.Player.Pipeline.handle_element_end_of_stream/4` never told the player to
  play the next track. A device on 2026-09-07 held a FLAC track of 3:44 at 5:32 and
  counted on. Every Jellyfin track of FLAC or of Ogg reached that state, and MP3 and
  AAC never did, because Membrane has a decoder for those two and it forwards the
  end of a stream itself.

  **The program cannot be told that its input ended.** A measurement on the device on
  2026-09-07 fed a whole FLAC file to `flac --decode --stdout --silent -` and held the
  pipe open for 20 seconds after the last byte: the program waited all 20 seconds and
  then exited. So it ends when its standard input ends, and not at the end of the
  stream that it reads. Erlang has no half close for a port, and
  `Port.close/1` ends the program and takes the output that it has not written yet.
  The `exit_status` clause below therefore never answers a track that reached its end.

  **This waits for the output to go quiet instead.** The end of the input starts a
  timer of a quarter of a second, each answer of the program starts it again, and the
  timer then closes the port and sends the end of the stream after the samples that
  `held` still keeps. A program that keeps
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

  # The length of the audio in one output buffer. The sink counts its queue in buffers,
  # and `@sink_queue_buffers` of `PiFi.Player.Pipeline` assumes the 23 to 26 ms frame
  # that MAD and FDK give. See "What limits the rate" above.
  @buffer_ms 25

  # How much decoded audio this element keeps before it stops feeding the program.
  @held_ms 250

  # How many compressed bytes one demand of the input asks for.
  @input_bytes 4096

  def_input_pad(:input, accepted_format: _any, flow_control: :manual, demand_unit: :bytes)

  def_output_pad(:output, accepted_format: %RawAudio{}, flow_control: :manual)

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            command: String.t(),
            arguments: [String.t()],
            port: port() | nil,
            held: binary(),
            format: RawAudio.t() | nil,
            flush_timer: reference() | nil,
            ending?: boolean(),
            ended?: boolean()
          }

    defstruct [
      :command,
      :arguments,
      :port,
      :format,
      :flush_timer,
      held: <<>>,
      ending?: false,
      ended?: false
    ]
  end

  @impl true
  def handle_init(_ctx, options) do
    {[], %State{command: options.command, arguments: options.arguments}}
  end

  @impl true
  def handle_playing(_ctx, %State{} = state) do
    state = %State{state | port: open(state)}
    {feeding(state), state}
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
    {feeding(state), state}
  end

  @impl true
  def handle_buffer(:input, _buffer, _ctx, state), do: {[], state}

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, %State{} = state) do
    {payloads, state} = take(state, size)
    {ending, state} = finishing(state)

    {buffers(payloads) ++ ending ++ feeding(state), state}
  end

  # The samples of the program arrive here. The header comes first, and the audio
  # after it.
  @impl true
  def handle_info({port, {:data, bytes}}, _ctx, %State{port: port} = state) do
    {actions, state} = read(state.held <> bytes, state)

    {actions ++ [redemand: :output] ++ feeding(state), waiting(state)}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, _ctx, %State{port: port} = state) do
    Membrane.Logger.error("#{state.command} stopped with status #{status}")
    if state.flush_timer, do: Process.cancel_timer(state.flush_timer)

    draining(%State{state | port: nil, flush_timer: nil})
  end

  # The program gave nothing for `@flush_ms`, so it has nothing more and the track
  # reached its end. See the module documentation for why this cannot wait for the
  # program to exit.
  @impl true
  def handle_info(:flush, _ctx, %State{} = state) do
    draining(close(state))
  end

  @impl true
  def handle_info(message, _ctx, state) do
    Membrane.Logger.debug("Ignoring #{inspect(message)}")
    {[], state}
  end

  # A port that is already closed leaves nothing to wait for.
  @impl true
  def handle_end_of_stream(:input, _ctx, %State{port: nil} = state) do
    draining(%State{state | ending?: true})
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

        {[stream_format: {:output, format}], %State{state | format: format, held: audio}}

      :more ->
        {[], %State{state | held: bytes}}
    end
  end

  defp read(audio, %State{} = state), do: {[], %State{state | held: audio}}

  defp buffers([]), do: []

  defp buffers(payloads) do
    [buffer: {:output, Enum.map(payloads, &%Membrane.Buffer{payload: &1})}]
  end

  # Whole buffers of `@buffer_ms` while the program runs. Once it has stopped, the
  # short piece at the end goes as well.
  defp take(%State{format: nil} = state, _count), do: {[], state}

  defp take(%State{} = state, count) do
    {payloads, rest} = split(state.held, buffer_bytes(state.format), count, state.port == nil)
    {payloads, %State{state | held: rest}}
  end

  defp split(bytes, size, count, last?, taken \\ [])

  defp split(bytes, _size, 0, _last?, taken), do: {Enum.reverse(taken), bytes}

  defp split(<<>>, _size, _count, _last?, taken), do: {Enum.reverse(taken), <<>>}

  defp split(bytes, size, count, last?, taken) when byte_size(bytes) >= size do
    <<payload::binary-size(^size), rest::binary>> = bytes
    split(rest, size, count - 1, last?, [payload | taken])
  end

  defp split(bytes, _size, _count, true, taken), do: {Enum.reverse([bytes | taken]), <<>>}

  defp split(bytes, _size, _count, false, taken), do: {Enum.reverse(taken), bytes}

  # The program has stopped, so what it left is all that is coming. `redemand` runs
  # `handle_demand/5`, which sends it and then the end of the stream.
  defp draining(%State{ended?: true} = state), do: {[], state}

  defp draining(%State{} = state) do
    case finishing(state) do
      {[], state} -> {[redemand: :output], state}
      ending -> ending
    end
  end

  # The end of the stream goes out after the last sample, and only once. Bytes held
  # before the header was whole are not audio, so they don't hold it back.
  defp finishing(%State{port: nil, ended?: false} = state)
       when state.held == <<>> or state.format == nil do
    {[end_of_stream: :output], %State{state | ended?: true}}
  end

  defp finishing(%State{} = state), do: {[], state}

  # Asked after anything that could change what the program needs: a write, an
  # answer, and a buffer that left. Asking only after an answer would stall a program
  # that needs more input before it can answer at all, such as `flac` reading a large
  # picture in the metadata.
  defp feeding(%State{ending?: true}), do: []
  defp feeding(%State{port: nil}), do: []

  defp feeding(%State{} = state) do
    if full?(state), do: [], else: [demand: {:input, @input_bytes}]
  end

  defp full?(%State{format: nil}), do: false

  defp full?(%State{} = state) do
    byte_size(state.held) >=
      RawAudio.time_to_bytes(Membrane.Time.milliseconds(@held_ms), state.format)
  end

  defp buffer_bytes(format),
    do: RawAudio.time_to_bytes(Membrane.Time.milliseconds(@buffer_ms), format)

  # A WAV file carries chunks. This reads the `fmt ` chunk for the shape of a sample,
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

  # A WAV file carries a signed sample of 16 bits or more, and an unsigned one of 8.
  defp sample_format(8), do: :u8
  defp sample_format(16), do: :s16le
  defp sample_format(24), do: :s24le
  defp sample_format(32), do: :s32le

  defp open(%State{} = state) do
    program =
      System.find_executable(state.command) ||
        raise """
        #{state.command} is not on the PATH.

        The Nerves system has no decoder for Ogg. NBPR gives the program, and it
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
