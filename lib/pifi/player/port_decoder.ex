defmodule PiFi.Player.PortDecoder do
  @moduledoc """
  Decodes audio with a program instead of a NIF.

  `PiFi.Output.APlaySink` already drives `aplay` through an Erlang port, and
  that pattern works on this board. This element uses it for a decoder: it writes
  the compressed bytes to a program, and it reads the samples from the standard
  output. The bytes go through a FIFO and not through the port, for the reason under
  "The end of a track" below.

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
  - **The input asks for more only while `held` is under `@held_ms`, and only once
    the program has gone quiet.** The program answers only for the bytes that it
    gets, so this is the one place that bounds its output. The next section explains
    the quiet part. `PiFi.Player.Pipeline` keeps the queue in front of this pad small
    as well.

  `busy_limits_port` on the port of the program, with the pads left on `:auto`, would
  not do this. The program never blocks on its output, so it reads its input as fast
  as it decodes, the pipe never fills, and the queue of the port never reaches a
  limit. The auto output would still send every answer to the sink.

  ## What the program hasn't answered yet

  **The program answers well behind its input, and nothing outside it says how far.**
  Input that goes in while `held` is short is still in the FIFO or inside the program
  when `held` reaches the bound, and its audio arrives later in one lump. This element
  used to ask for 4 KB after every write while `held` was under the bound, so each
  dip under it let in as much as the program would take.
  A measurement on the host on 2026-11-01, with `Membrane.File.Source`, this element,
  `PiFi.Output.APlaySink` and a fake `aplay` that reads at the rate of the audio, found
  `held` at up to 1.7 s of FLAC and 7.6 s of Vorbis.

  How far behind depends on the program and the file. Feeding the start of a file and
  holding the pipe open showed:

  - `flac` answers two or three frames behind. It writes its header after 12 KB of a
    16-bit file, and its first audio after 32 KB of a 24-bit 96 kHz one. It writes
    nothing at all until it has read past a picture in the metadata, and 3 or 4 MB is
    normal there.
  - `oggdec` and `flac --ogg` answer a page at a time. `oggenc` writes pages of about
    4 KB, which is 0.4 s, and ffmpeg writes a second of audio in each page.
  - `flac --ogg` also keeps 64 KB of samples in its output buffer.

  So one request is in flight at a time:

  - **A request goes out only when the program is quiet**, which means no write and
    no answer for `@quiet_ms`. Both programs decode far faster than the audio plays,
    so a quiet program is waiting for input, and what it holds is only what it can't
    answer yet.
  - **A request asks for the audio that `held` lacks**, and one buffer at least. The
    compressed bytes for that come from the ratio of what the program has answered to
    what it has been given since its header. The bytes before the header are the
    metadata, and a picture there would make the ratio worthless.
  - **A request that gets no answer doubles the next one.** That's what gets `flac`
    past a picture: eleven requests from 4 KB cover 4 MB. After the header it carries a
    program through a page in a few steps. The overshoot is never more than the
    program needed.
  - **The header cancels what's left of the input's demand.** A request that doubled
    its way past the metadata is asking for audio now.

  The same measurement afterwards:

  | File                      | `held` peak before | after  | source ahead of card before | after     |
  | ------------------------- | ------------------ | ------ | --------------------------- | --------- |
  | FLAC 16-bit 44.1 kHz      | 1.70 s             | 0.47 s | 1.8 to 2.5 s                | 1.4 to 1.6 s |
  | FLAC 24-bit 96 kHz        | 0.63 s             | 0.49 s | 0.9 to 1.0 s                | 0.8 to 0.9 s |
  | FLAC with a 4 MB picture  | 1.72 s             | 0.53 s | 1.4 to 2.2 s                | 1.6 to 1.7 s |
  | Ogg FLAC from `flac`      | 1.73 s             | 0.85 s | 2.5 to 2.9 s                | 1.6 to 1.9 s |
  | Ogg FLAC from ffmpeg      | 1.88 s             | 1.55 s | 2.6 to 3.5 s                | 2.4 to 3.7 s |
  | Vorbis from `oggenc`      | 7.61 s             | 1.15 s | 4.3 to 6.2 s                | 2.5 to 2.7 s |
  | Vorbis from ffmpeg        | 6.85 s             | 2.14 s | 3.3 to 5.4 s                | 2.3 to 3.3 s |

  About 1.2 s of the lead in that harness is past this element: the queue of the sink,
  the busy limits of `PiFi.Output.APlayPort` and the pipe into the fake card. A file
  with pages of a second still lands a second of audio at a time, because the program
  can't answer half a page.

  **The cost is speed.** A decode into a sink that never waits now runs at 10 to 20
  times the speed of the audio rather than hundreds of times, which is still far more than a sound card
  takes. The first audio arrived 30 to 90 ms after the start, and 250 ms after it for
  the file with a 4 MB picture, which is the eleven quiet periods. A skip of FLAC
  builds a new decoder, so it pays the 30 to 90 ms.

  **A slow program looks quiet.** A program that goes `@quiet_ms` without an answer
  while it still has input gets the next request early, and that request doubles.
  Neither program came near that on the host. On the board it would take a decode of
  one FLAC frame or one Vorbis page that lasts 20 ms.

  **Rejected:**

  - A cap on the bytes written since the last answer. The program keeps answering for
    earlier input, so the count starts again while new input piles up behind it. As a
    fixed number it also stopped 24-bit FLAC and Vorbis before their header, and
    `flac` inside a picture.
  - The ratio alone, with no quiet timer. A ratio taken from the same totals that it
    checks always says that nothing is outstanding. And a program that holds half a
    page waits for more input while this element waits for its audio, so the two stop.
  - Reading how far the program has read from `/proc/<pid>/io`. That needs a kernel
    option that this Nerves system may not have, and it can't see the program's own
    buffer either.

  ## The end of a track, and the half close that Erlang doesn't have

  **The end of the input must reach the output, or the track never ends.** This
  element closed the port and sent nothing when its input ended, so the sink kept its
  card open, `aplay` played the queue and then silence, and
  `PiFi.Player.Pipeline.handle_element_end_of_stream/4` never told the player to
  play the next track. A device on 2026-09-07 held a FLAC track of 3:44 at 5:32 and
  counted on. Every Jellyfin track of FLAC or of Ogg reached that state, and MP3 and
  AAC never did, because Membrane has a decoder for those two and it forwards the
  end of a stream itself.

  **The program ends when its standard input closes, and it keeps the tail of the
  audio until then.** A measurement on the device on 2026-09-07 fed a whole FLAC file
  to `flac --decode --stdout --silent -` and held the pipe open for 20 seconds after
  the last byte: the program waited all 20 seconds and then exited. Both programs
  also hold back output until that close. Erlang has no half close for a port:
  `open_port/2` of OTP 29 has no option for it, no release of ERTS added one, and
  `Port.close/1` closes the input and the output together, so the program's last
  write goes to a closed pipe.

  This element used to wait for a quarter of a second of quiet after the end of its
  input and then close the port. That threw away the tail. A measurement on the host
  on 2026-11-01, with 3 s of pink noise through `Membrane.File.Source`, this element
  and a sink that counts bytes, lost the end of every track: 0.075 to 0.12 s of FLAC
  (it depends on the encoder), 0.1 s of 24-bit 96 kHz FLAC, 0.5 to 0.7 s of Ogg FLAC
  and 1.0 s of Vorbis. Other files lost up to 0.4 s of FLAC and 1.1 s of Ogg FLAC.

  **So the program reads a named pipe, and the port carries its output alone.**
  `open/1` makes a FIFO in `System.tmp_dir!/0`, starts the program through
  `sh -c 'exec "$@" < fifo'` on a port opened `:in`, and opens the FIFO for writing.
  The compressed bytes go into the FIFO, and the end of the input closes it, which is
  the end of input that the program waits for. It writes the rest of the audio and
  exits, and its `exit_status` arrives after the last of its output: the spawn driver
  of ERTS (`sys_drivers.c`) reports the status only from the path that has read the
  program's output to its end. That status is what ends the stream now. The same
  measurement then gave every sample of every file, and of a FLAC with a 4.4 MB
  picture.

  Traps in this, each of which matters:

  - **The Nerves system's busybox has no `mkfifo`,** but it has `mknod`, and
    `mknod NAME p` makes the same thing. Only `/root` and the tmpfs mounts are
    writable on the device, and erlinit mounts `/tmp` as tmpfs, so the FIFO costs
    the SD card nothing.
  - **Opening a FIFO blocks until the other end opens.** The port starts first, so
    the shell is already waiting on the read end when this element opens the write
    end, and both opens return together. This element then removes the name: the
    two open ends keep the pipe alive, and an element that dies leaves nothing
    behind, unless it dies between `mknod` and the open.
  - **Open the FIFO write only.** A read end held here as well would keep a write
    from failing when the program has exited, and a full pipe would then block this
    element forever. With a write-only end, a program that has gone makes the write
    fail with `:epipe`, which is ignored, and the `exit_status` that follows ends
    the stream.
  - **A stop closes both ends.** `Port.close/1` alone would leave the program waiting
    for more input. Closing the FIFO gives it the end of its input, and its next
    write to the closed port kills it, which is how a stop ended it before.

  No quiet timer is left. The program exits once its input closes, so its exit is a
  real end, and a timer could only cut the end off a decode that ran slowly, which is
  the bug this replaced. A program that never exits after its input closes would hold
  the track open, and neither program does that.

  **Rejected:**

  - A wrapper script in `priv` that reads framed input and closes the program's
    input on an end marker. busybox has neither `head` nor `od` here, and the shell's
    `read` can't take binary, so each frame needs a `dd` process: 16 a second for
    a CD-quality FLAC and 70 for 24-bit 96 kHz.
  - A library with a half close, such as Exile. It needs a NIF, and the FIFO needs
    nothing that the board lacks.
  """

  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.RawAudio

  # `open/1` builds the FIFO's path from the temporary directory, the OS pid and a
  # unique integer, and nothing from outside, so the traversal findings on it are not
  # correct. Sobelow reads `@sobelow_skip` from the source. This registration stops the
  # compiler warning that no Elixir code reads the attribute.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

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

  # `$0` is the FIFO and the rest is the program and its arguments, so neither needs
  # quoting. `exec` makes the port's process the program itself, so its exit status
  # is the program's.
  @from_fifo ~S(exec "$@" < "$0")

  # The length of the audio in one output buffer. The sink counts its queue in buffers,
  # and `@sink_queue_buffers` of `PiFi.Player.Pipeline` assumes the 23 to 26 ms frame
  # that MAD and FDK give. See "What limits the rate" above.
  @buffer_ms 25

  # How much decoded audio this element keeps before it stops feeding the program.
  @held_ms 250

  # How many compressed bytes the first request asks for, before the program has
  # answered enough to give a ratio. A request that gets no answer doubles it.
  @input_bytes 4096

  # How long the program must go without a write or an answer before this element
  # takes it to be waiting for input. See "What the program hasn't answered yet".
  @quiet_ms 20

  def_input_pad(:input, accepted_format: _any, flow_control: :manual, demand_unit: :bytes)

  def_output_pad(:output, accepted_format: %RawAudio{}, flow_control: :manual)

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            command: String.t(),
            arguments: [String.t()],
            port: port() | nil,
            input: :file.io_device() | nil,
            held: binary(),
            format: RawAudio.t() | nil,
            busy: reference() | nil,
            stalls: non_neg_integer(),
            asked?: boolean(),
            written: non_neg_integer(),
            answered: non_neg_integer(),
            ending?: boolean(),
            ended?: boolean()
          }

    defstruct [
      :command,
      :arguments,
      :port,
      :input,
      :format,
      :busy,
      held: <<>>,
      stalls: 0,
      asked?: false,
      written: 0,
      answered: 0,
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
    state |> open() |> feeding()
  end

  # The format of the input says nothing about the samples, and the default
  # implementation of a filter forwards it. The output pad takes `RawAudio` only,
  # so that forward stops the pipeline. This element names its own format when it
  # reads the WAV header of the program.
  @impl true
  def handle_stream_format(:input, _format, _ctx, state), do: {[], state}

  @impl true
  def handle_buffer(:input, buffer, _ctx, %State{input: input} = state) when input != nil do
    # `{:error, :epipe}` means that the program has exited, and its `exit_status`
    # ends the stream.
    _written = :file.write(input, buffer.payload)
    written = counted(state, state.written, buffer.payload)
    {[], busy(%State{state | written: written, asked?: false})}
  end

  @impl true
  def handle_buffer(:input, _buffer, _ctx, state), do: {[], state}

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, %State{} = state) do
    {payloads, state} = take(state, size)
    {ending, state} = finishing(state)

    {feeding, state} = feeding(state)

    {buffers(payloads) ++ ending ++ feeding, state}
  end

  # The samples of the program arrive here. The header comes first, and the audio
  # after it.
  @impl true
  def handle_info({port, {:data, bytes}}, _ctx, %State{port: port} = state) do
    answered = counted(state, state.answered, bytes)
    {actions, state} = read(state.held <> bytes, state)
    {actions ++ [redemand: :output], busy(%State{state | answered: answered, stalls: 0})}
  end

  # The program has neither read nor answered for `@quiet_ms`, so it waits for input.
  @impl true
  def handle_info({:timeout, busy, :quiet}, _ctx, %State{busy: busy} = state) do
    feeding(%State{state | busy: nil})
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, _ctx, %State{port: port} = state) do
    log_exit(state, status)

    draining(%State{close_input(state) | port: nil})
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

  # Closing the FIFO is the end of input that the program waits for. It then writes
  # the rest and exits, and its `exit_status` ends the stream.
  @impl true
  def handle_end_of_stream(:input, _ctx, %State{} = state) do
    {[], close_input(%State{state | ending?: true})}
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

        {[stream_format: {:output, format}, demand: {:input, 0}],
         %State{state | format: format, held: audio, asked?: false}}

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
  # answer, the program going quiet, and a buffer that left.
  defp feeding(%State{ending?: true} = state), do: {[], state}
  defp feeding(%State{port: nil} = state), do: {[], state}
  defp feeding(%State{asked?: true} = state), do: {[], state}
  defp feeding(%State{busy: busy} = state) when busy != nil, do: {[], state}

  defp feeding(%State{} = state) do
    case wanted(state) do
      0 ->
        {[], state}

      bytes ->
        demand = bytes * Integer.pow(2, state.stalls)
        {[demand: {:input, demand}], %State{state | stalls: state.stalls + 1, asked?: true}}
    end
  end

  defp wanted(%State{format: nil}), do: @input_bytes

  defp wanted(%State{} = state) do
    case missing(state) do
      0 -> 0
      audio -> input_for(audio, state)
    end
  end

  # How much audio this element lacks of `@held_ms`, and at least one buffer, so that
  # the program is never asked for a few bytes.
  defp missing(%State{} = state) do
    held_bytes = RawAudio.time_to_bytes(Membrane.Time.milliseconds(@held_ms), state.format)

    case held_bytes - byte_size(state.held) do
      missing when missing > 0 -> max(missing, buffer_bytes(state.format))
      _enough -> 0
    end
  end

  # The compressed bytes that give `audio` bytes of samples, at the ratio that the
  # program has answered so far.
  defp input_for(_audio, %State{answered: 0}), do: @input_bytes
  defp input_for(_audio, %State{written: 0}), do: @input_bytes
  defp input_for(audio, %State{} = state), do: div(audio * state.written, state.answered) + 1

  # Bytes count from the header on. The bytes before it carry the metadata, and a
  # FLAC picture of 4 MB there would make the ratio worthless.
  defp counted(%State{format: nil}, count, _bytes), do: count
  defp counted(%State{}, count, bytes), do: count + byte_size(bytes)

  # A write or an answer means the program may still be at work, so the quiet timer
  # starts again.
  defp busy(%State{busy: nil} = state) do
    %State{state | busy: :erlang.start_timer(@quiet_ms, self(), :quiet)}
  end

  defp busy(%State{busy: busy} = state) do
    _left = :erlang.cancel_timer(busy)
    busy(%State{state | busy: nil})
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

  @sobelow_skip ["Traversal.FileModule"]
  defp open(%State{} = state) do
    program =
      System.find_executable(state.command) ||
        raise """
        #{state.command} is not on the PATH.

        The Nerves system has no decoder for Ogg. NBPR gives the program, and it
        ships a binary and no header file, which is all that a port needs. See
        <https://github.com/jimsynz/nbpr>.
        """

    fifo = fifo()

    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        :in,
        args: ["-c", @from_fifo, fifo, program | state.arguments]
      ])

    # Returns once the shell has opened the read end. See the module documentation.
    {:ok, input} = File.open(fifo, [:write, :raw, :binary])
    File.rm!(fifo)

    %State{state | port: port, input: input}
  end

  defp fifo do
    fifo =
      Path.join(
        System.tmp_dir!(),
        "pifi-decoder-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    {_output, 0} = System.cmd("mknod", [fifo, "p"], stderr_to_stdout: true)
    fifo
  end

  defp log_exit(%State{ending?: true} = state, 0) do
    Membrane.Logger.debug("#{state.command} finished")
  end

  defp log_exit(%State{} = state, status) do
    Membrane.Logger.error("#{state.command} stopped with status #{status}")
  end

  defp close(%State{port: nil} = state), do: close_input(state)

  defp close(%State{port: port} = state) do
    if Port.info(port), do: Port.close(port)

    close_input(%State{state | port: nil})
  end

  defp close_input(%State{input: nil} = state), do: state

  defp close_input(%State{input: input} = state) do
    File.close(input)
    %State{state | input: nil}
  end
end
