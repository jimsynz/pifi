defmodule MyHiFi.Player.FileSource do
  @moduledoc """
  A Membrane source that reads audio from a file while that file grows.

  `MyHiFi.Player.Download` writes the file as fast as the network allows, and this
  element reads it at the speed of the sound card. **A file needs no flow control.**
  The demand of Membrane reaches the pad of an element and it cannot reach a socket
  that another library owns, which is why `MyHiFi.Player.HttpSource` dropped the
  audio of a podcast. Nothing here can arrive faster than a read asks for it.

  The file is the buffer, so this element keeps no queue. `:file.pread/3` returns the
  bytes that a demand asks for, and the rest wait on the disk.

  ## What it waits for

  It reads no further than the bytes that the download reports. At that point it
  gives no buffer, and a `{:download, {:bytes, count}}` message wakes it. A person
  then hears silence for as long as the network is slower than the audio, which is
  what a live stream does today.

  It sends `end_of_stream` when it reaches the end of a file that the download
  called whole. A file that the cache already keeps is whole from the start, so an
  episode that a person plays a second time asks the network for nothing.

  ## Where it starts

  `position_bytes` is the byte that the person stopped at.
  `MyHiFi.Player.Download` and this element make a resume exact: the reader knows
  the byte and the player knows the time, so no part of this firmware turns one into
  the other. A bitrate cannot do that, because 11 of 46 real episodes hold more than
  one.
  """

  use Membrane.Source

  require Membrane.Logger

  alias MyHiFi.Player.Download
  alias MyHiFi.Player.FlacFrame
  alias MyHiFi.Player.Skip

  # How far the reader moves before it tells the player where it is. 16 KB is about
  # one second of a 128 kbit/s episode.
  @tell_every 16 * 1024

  # **The largest buffer that may leave this element.** `Membrane.MP3.MAD.Decoder`
  # decodes a whole input buffer in one callback: `decode_buffer/5` recurses to the
  # end of it and blocks every action until it returns. A buffer of a whole 49.7 MB
  # episode therefore asks it to decode 3108 seconds at once, and that is 822 MB of
  # `s24le` samples on a board with 363.9 MB.
  #
  # A read on 2026-08-24 did exactly that. The board raised its memory alarm, the
  # decoder reported a malformed frame for each byte that it then skipped, and a
  # person heard noise. `MyHiFi.Player.HttpSource` never met this, because a part of
  # a network answer is a few kilobytes.
  #
  # 16 KB is about one second of a 128 kbit/s episode, and about 38 frames.
  @read_bytes 16 * 1024

  # How far a resume steps back before the byte that it reads.
  #
  # **The byte that a resume starts at is in front of what a person heard.** This
  # element reports the byte that it read, and the pipeline runs ahead of the sound: a
  # read on the board on 2026-08-24 measured 1.7 s after a short play and 3.8 s after
  # a longer one, and 3.8 s of a 128 kbit/s episode is 61 KB. 96 KB therefore covers
  # more than the largest lead that a read has measured, so a person hears a little
  # again and never loses a word.
  #
  # Bytes and not milliseconds, because the lead is itself a count of bytes and a
  # count of bytes needs no bitrate.
  @rewind_bytes 96 * 1024

  def_options(
    key: [
      spec: String.t(),
      description: "The key that a download writes this track under."
    ],
    uri: [
      spec: String.t(),
      description: "The address of the audio, for a download that has not run."
    ],
    position_bytes: [
      spec: non_neg_integer(),
      default: 0,
      description: "The byte to begin at. It is 0 for a track that begins at the start."
    ],
    format: [
      spec: atom(),
      default: :mp3,
      description: """
      The codec of the file. A resume steps back to a frame boundary, and
      `MyHiFi.Player.Skip.frames/1` says which codecs carry frames that this
      firmware reads.
      """
    ],
    skip_ms: [
      spec: integer(),
      default: 0,
      description: """
      How far to move from `position_bytes` before the first byte leaves this
      element. **A decoder that holds the state of a stream cannot take a skip while
      it runs**, so `MyHiFi.Player` builds the pipeline again and gives the skip
      here. It is 0 for every other start.
      """
    ],
    buffer_bytes: [
      spec: pos_integer(),
      default: 64 * 1024,
      description: """
      How many bytes the file must hold before the first sound. It hides a
      network that is slower than the audio for a moment.
      """
    ]
  )

  # `demand_unit: :bytes` is not optional. Without it a manual output pad takes the
  # default unit and the `handle_demand/5` clause below never matches. See
  # `MyHiFi.Player.HttpSource`, where that cost a build to find.
  def_output_pad(:output,
    accepted_format: %Membrane.RemoteStream{},
    flow_control: :manual,
    demand_unit: :bytes
  )

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            key: String.t(),
            uri: String.t(),
            format: atom(),
            skip_ms: integer(),
            prefix: binary(),
            device: :file.fd() | nil,
            offset: non_neg_integer(),
            available: non_neg_integer(),
            demand: non_neg_integer(),
            buffer_bytes: pos_integer(),
            filling?: boolean(),
            whole?: boolean(),
            told: non_neg_integer()
          }

    defstruct [
      :key,
      :uri,
      :device,
      format: :mp3,
      skip_ms: 0,
      prefix: <<>>,
      offset: 0,
      available: 0,
      demand: 0,
      buffer_bytes: 64 * 1024,
      filling?: true,
      whole?: false,
      told: 0
    ]
  end

  @impl true
  def handle_init(_ctx, options) do
    {[],
     %State{
       key: options.key,
       uri: options.uri,
       offset: options.position_bytes,
       format: options.format,
       skip_ms: options.skip_ms,
       buffer_bytes: options.buffer_bytes
     }}
  end

  @impl true
  def handle_playing(_ctx, %State{} = state) do
    # This element and not the pipeline asks for the download, because the caller of
    # `ensure/2` becomes the watcher and this is the process that waits for the
    # bytes.
    case Download.ensure(state.key, state.uri) do
      {:ok, %{paths: paths, complete?: whole?}} ->
        {state, moved} = state |> open(paths, whole?) |> sought()
        state = prefixed(state)

        {[stream_format: {:output, %Membrane.RemoteStream{}}] ++ moved, state}

      {:error, reason} ->
        raise "Could not read #{state.uri}: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_demand(:output, size, :bytes, _ctx, %State{} = state) do
    serve(%State{state | demand: state.demand + size})
  end

  # A skip moves the byte that this element reads, and the pipeline keeps playing. A
  # start of a pipeline would open the sound card again, and it would hold a silence of
  # about one second. See `MyHiFi.Player.Skip`.
  #
  # The audio that already left this element still plays: the queue of the decoder and
  # the queue of the port hold about one and a half seconds of it.
  @impl true
  def handle_parent_notification({:skip, _ms}, _ctx, %State{device: nil} = state) do
    {[], state}
  end

  @impl true
  def handle_parent_notification({:skip, ms}, _ctx, %State{} = state) do
    case placed(state, ms) do
      {:ok, place} ->
        Membrane.Logger.info("A skip of #{ms} ms moved #{place.ms} ms, to #{place.byte}.")

        {actions, state} = serve(%State{state | offset: place.byte, told: place.byte})

        {[notify_parent: {:skipped, place}] ++ actions, state}

      {:error, reason} ->
        Membrane.Logger.warning("Could not skip #{ms} ms: #{inspect(reason)}")
        {[], state}
    end
  end

  @impl true
  def handle_parent_notification(_notification, _ctx, %State{} = state), do: {[], state}

  # **A skip reads the disk, and a person presses the control again and again.** A
  # forward skip steps over 480 KB for 30 seconds of a 128 kbit/s file, and a backward
  # one measures what it chose. The span says how long that reading takes, and the
  # direction says which of the two paths did it. See `MyHiFi.Player.Skip`.
  defp placed(%State{} = state, ms) do
    metadata = %{direction: direction(ms), format: state.format}

    :telemetry.span([:my_hi_fi, :player, :skip], metadata, fn ->
      result = Skip.place(state.device, state.offset, ms, state.available, state.format)
      {result, moved(metadata, result)}
    end)
  end

  defp direction(ms) when ms < 0, do: :backward
  defp direction(_ms), do: :forward

  defp moved(metadata, {:ok, place}), do: Map.put(metadata, :moved_ms, abs(place.ms))
  defp moved(metadata, {:error, _reason}), do: Map.put(metadata, :moved_ms, 0)

  @impl true
  def handle_info({:download, {:bytes, count}}, _ctx, %State{} = state) do
    serve(%State{state | available: count})
  end

  @impl true
  def handle_info({:download, :done}, _ctx, %State{} = state) do
    serve(%State{state | available: held_bytes(state), whole?: true})
  end

  @impl true
  def handle_info({:download, {:error, reason}}, _ctx, %State{} = state) do
    raise "Could not read #{state.uri}: #{inspect(reason)}"
  end

  @impl true
  def handle_info(message, _ctx, %State{} = state) do
    Membrane.Logger.debug("Ignoring #{inspect(message)}")
    {[], state}
  end

  @impl true
  def handle_terminate_request(_ctx, %State{device: nil} = state),
    do: {[terminate: :normal], state}

  @impl true
  def handle_terminate_request(_ctx, %State{} = state) do
    :file.close(state.device)
    {[terminate: :normal], %State{state | device: nil}}
  end

  # A download that finishes between the answer of `ensure/2` and this open moves the
  # file, so both names come back and one of them is there.
  defp open(%State{} = state, paths, whole?) do
    case Enum.find_value(paths, &opened(&1)) do
      {device, size} ->
        %State{
          state
          | device: device,
            available: size,
            whole?: whole?,
            offset: state.offset |> begun(device, state) |> begin_at(size, whole?)
        }

      nil ->
        raise "No file of #{state.key} at #{inspect(paths)}"
    end
  end

  @doc """
  The byte that a resume begins at, given the byte that the item reports.

  It steps back by `@rewind_bytes` and it lands on a frame boundary. See
  `MyHiFi.Player.Mp3Frame` for both reasons.

  This function is public so that a test can reach it, as `MyHiFi.Player.HttpSource`
  makes `trim/1` public. A caller inside this module is the only one that needs it.
  """
  @spec rewound(non_neg_integer(), :file.fd(), atom()) :: non_neg_integer()
  def rewound(offset, _device, _format) when offset <= 0, do: 0

  def rewound(offset, device, format) do
    with {:ok, frames} <- Skip.frames(format),
         {:ok, byte} <- frames.boundary_before(device, offset, @rewind_bytes) do
      Membrane.Logger.info("A resume of #{offset} begins at #{byte}.")
      byte
    else
      # A codec that no reader holds, and a file with no frame where this looked,
      # both still play. The step back is what stops a person from losing a word, and
      # the alignment costs the decoder under two frames when it is absent.
      {:error, reason} ->
        Membrane.Logger.warning("Could not align a resume of #{offset}: #{inspect(reason)}")
        max(offset - @rewind_bytes, 0)
    end
  end

  # **A pipeline that begins with a skip does the skip here**, before a byte leaves
  # this element, so the decoder reads one stream and never two. `MyHiFi.Player`
  # builds the pipeline again for a codec whose decoder holds the state of the
  # stream. See `MyHiFi.Player.Pipeline.decoder_holds_stream?/1`.
  #
  # The parent learns the time that this really moved, in the same notification that
  # a skip of a running pipeline sends, so the count that a person reads follows the
  # audio either way.
  # **A decoder that reads a container needs the head of the file.** A stream that
  # begins in the middle of the audio carries no STREAMINFO, so `flac` wrote a WAV
  # header of `channels: 0` and `bits: 0` and `MyHiFi.Player.PortDecoder` stopped on
  # it. `MyHiFi.Player.FlacFrame.header/1` gives the 42 bytes that answer it, and
  # they go in front of the first frame.
  #
  # A start at the first byte needs none of this, because the file carries its own
  # head. MP3 and AAC need none either: a frame of those names its own rate and
  # width.
  defp prefixed(%State{offset: 0} = state), do: state

  defp prefixed(%State{format: :flac} = state) do
    case FlacFrame.header(state.device) do
      {:ok, header} ->
        %State{state | prefix: header}

      {:error, reason} ->
        Membrane.Logger.warning("Could not read the head of the file: #{inspect(reason)}")
        state
    end
  end

  defp prefixed(%State{} = state), do: state

  defp sought(%State{skip_ms: 0} = state), do: {state, []}

  defp sought(%State{} = state) do
    case placed(state, state.skip_ms) do
      {:ok, place} ->
        Membrane.Logger.info(
          "A start at #{state.offset} with a skip of #{state.skip_ms} ms moved " <>
            "#{place.ms} ms, to #{place.byte}."
        )

        state = %State{state | offset: place.byte, told: place.byte, skip_ms: 0}

        {state, [notify_parent: {:skipped, place}]}

      {:error, reason} ->
        Membrane.Logger.warning("Could not skip #{state.skip_ms} ms: #{inspect(reason)}")

        {%State{state | skip_ms: 0}, []}
    end
  end

  # **A pending skip needs the byte that it was given, and no step back.** The step
  # back belongs to a resume, where this element read further than a person heard. A
  # skip names a place that no person has heard, so 96 KB before it is 96 KB of the
  # wrong audio.
  defp begun(offset, _device, %State{skip_ms: skip_ms}) when skip_ms != 0, do: offset

  defp begun(offset, device, %State{format: format}), do: rewound(offset, device, format)

  # A place past the end of a whole file means the person reached the end, so this
  # begins there and the stream ends at once. A place past the end of a file that
  # still grows is a place that the download has not reached, and `serve/1` waits for
  # it. Holding that place is the reason that a resume is exact.
  defp begin_at(offset, size, true), do: min(offset, size)
  defp begin_at(offset, _size, false), do: offset

  defp opened(path) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         {:ok, device} <- :file.open(path, [:read, :binary, :raw]) do
      {device, size}
    else
      {:error, _reason} -> nil
    end
  end

  # Nothing leaves this element until the file has enough to hide a network that
  # falls behind the audio for a moment. A whole file passes at once.
  defp serve(%State{filling?: true, whole?: false} = state) do
    if state.available - state.offset >= state.buffer_bytes do
      Membrane.Logger.info("The file has #{state.available} bytes. Playing.")
      serve(%State{state | filling?: false})
    else
      {[], state}
    end
  end

  defp serve(%State{filling?: true} = state), do: serve(%State{state | filling?: false})

  defp serve(%State{demand: 0} = state), do: {[], state}

  defp serve(%State{} = state) do
    case servable(state) do
      size when size > 0 -> read(state, size)
      _none -> {ending(state), state}
    end
  end

  defp servable(%State{} = state) do
    state.demand |> min(state.available - state.offset) |> min(@read_bytes) |> max(0)
  end

  defp read(%State{} = state, size) do
    case :file.pread(state.device, state.offset, size) do
      {:ok, payload} ->
        state = %State{
          state
          | offset: state.offset + byte_size(payload),
            demand: state.demand - byte_size(payload)
        }

        {actions, state} = telling(state)

        {[buffer: {:output, %Membrane.Buffer{payload: state.prefix <> payload}}] ++
           actions ++ continuing(state), %State{state | prefix: <<>>}}

      # The file is shorter than the count that the download reported, so the next
      # message says what it really is.
      :eof ->
        {[], state}

      {:error, reason} ->
        raise "Could not read the file of #{state.key}: #{inspect(reason)}"
    end
  end

  # One buffer carries `@read_bytes` at most, so a demand larger than that needs more
  # than one turn. `:redemand` asks Membrane for that turn. The demand falls with each
  # buffer, so this ends.
  defp continuing(%State{} = state) do
    case {ending(state), servable(state)} do
      {[], more} when more > 0 -> [redemand: :output]
      {ending, _more} -> ending
    end
  end

  defp ending(%State{whole?: true, offset: offset, available: available})
       when offset >= available,
       do: [end_of_stream: :output]

  defp ending(%State{}), do: []

  # The player writes this byte beside the time when a person stops, and the two
  # together make a resume exact. It goes out each `@tell_every` bytes and not on
  # each buffer: at 128 kbit/s that is about one message each second, and a buffer is
  # about 50 ms of sound.
  defp telling(%State{offset: offset, told: told} = state) when offset - told >= @tell_every do
    {[notify_parent: {:position_bytes, offset}], %State{state | told: offset}}
  end

  defp telling(%State{} = state), do: {[], state}

  defp held_bytes(%State{device: device}) do
    case :file.position(device, :eof) do
      {:ok, size} -> size
      {:error, _reason} -> 0
    end
  end
end
