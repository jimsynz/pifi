defmodule MyHiFi.Player.Pipeline do
  @moduledoc """
  The Membrane pipeline that plays one stream.

  Three facts of `MyHiFi.Source.playable/0` build it: the transport, the
  container, and the codec.

      :http, :none,    :mp3  ->  HTTP source -> MAD -> sink
      :http, :none,    :aac  ->  HTTP source -> FDK -> sink
      :hls,  :none,    :aac  ->  HLS source -> ID3 removal -> AAC parser -> FDK -> sink
      :hls,  :mpeg_ts, :aac  ->  HLS source -> demuxer -> AAC parser -> FDK -> sink
      :hls,  :mpeg_ts, :mp3  ->  HLS source -> demuxer -> timestamp removal -> MAD -> sink
      :http, :ogg,     :vorbis -> HTTP source -> oggdec port -> sink
      :http, :ogg,     :flac   -> HTTP source -> flac --ogg port -> sink
      :http, :none,    :flac   -> HTTP source -> flac port -> sink

  An HTTP source owns the ring buffer, so the compressed bytes wait there and the
  samples never do. An HLS source reads the segments of the playlist instead, and
  the playlist gives the buffer.

  The player starts one of these at a time, and it stops the old one first.
  """

  use Membrane.Pipeline

  alias MyHiFi.Player.FileSource
  alias MyHiFi.Player.Hls
  alias MyHiFi.Player.HttpSource
  alias MyHiFi.Player.PortDecoder

  # How many decoded buffers may wait at the sink. Membrane gives 400 by default,
  # and a buffer of MP3 samples is about 50 ms, so the default lets 20 seconds of
  # samples pile up in front of `aplay`. The sink writes to a port and the write
  # blocks, so the sink cannot read its own mailbox while it waits, and a request
  # to stop waits behind all of those samples. A person then presses stop and
  # hears several more seconds of music.
  #
  # Eight buffers is under half a second. ALSA keeps another half second, and the
  # decoder runs much faster than the sound, so the sound stays smooth.
  @sink_queue_buffers 8

  # How many bytes of AAC may reach the decoder in one buffer. The field that
  # carries the length of an ADTS frame is 13 bits, so 8191 bytes is the largest
  # frame that the format allows, and this size therefore always carries a whole
  # frame. It is also well under the input buffer of libfdk-aac: a measurement of
  # a 128 kbps stream lost no audio at 16 KB and lost most of it at 32 KB. See
  # `adapter/2`.
  @fdk_input_bytes 8192

  # How many bytes of MP3 may wait in the queue of the decoder. This is not about
  # what MAD can hold: it is the lead that the pipeline keeps over the sound, and
  # that lead decides how far a resume lands from the place that a person stopped
  # at. 16 KB is about one second of a 128 kbit/s episode. See `adapter/2`.
  @mad_input_bytes 16 * 1024

  @impl true
  def handle_init(_ctx, options) do
    playable = options.playable

    spec =
      playable
      |> source(options.buffer_bytes)
      |> demuxer(playable.container)
      |> adapter(playable)
      |> decoder(playable)
      |> via_in(:input, auto_demand_size: @sink_queue_buffers)
      |> child(:sink, options.sink)

    {[spec: spec], %{parent: options.parent}}
  end

  @doc """
  What the player asks of a pipeline that runs.

  `:silence` stops the sound now. The player answers a person before it takes the
  pipeline down, so the sink becomes a null sink and the teardown happens after. See
  `MyHiFi.Player`.

  `{:skip, ms}` moves the reader of the source, and the pipeline keeps playing. `ms`
  is signed, so a backward skip is a negative number. This answers before the source
  reads the disk, and the source reports the time that it really moved. See
  `MyHiFi.Player.Skip`.
  """
  @impl true
  def handle_call(:silence, _ctx, state) do
    {[reply: :ok, notify_child: {:sink, :silence}], state}
  end

  @impl true
  def handle_call({:skip, ms}, _ctx, state) do
    {[reply: :ok, notify_child: {:source, {:skip, ms}}], state}
  end

  # The sink says when sound starts, and not the source. Every transport reaches
  # the sink, and only the sink knows that samples arrived.
  @impl true
  def handle_child_notification(:playing, :sink, _ctx, state) do
    send(state.parent, {:pipeline_playing, self()})
    {[], state}
  end

  @impl true
  def handle_child_notification({:metadata, title}, :source, _ctx, state) do
    send(state.parent, {:pipeline_metadata, self(), title})
    {[], state}
  end

  @impl true
  def handle_child_notification({:position_bytes, bytes}, :source, _ctx, state) do
    send(state.parent, {:pipeline_position_bytes, self(), bytes})
    {[], state}
  end

  @impl true
  def handle_child_notification({:skipped, place}, :source, _ctx, state) do
    send(state.parent, {:pipeline_skipped, self(), place})
    {[], state}
  end

  @impl true
  def handle_child_notification(_notification, _child, _ctx, state), do: {[], state}

  @impl true
  def handle_element_end_of_stream(:sink, :input, _ctx, state) do
    send(state.parent, {:pipeline_finished, self()})
    {[], state}
  end

  @impl true
  def handle_element_end_of_stream(_element, _pad, _ctx, state) do
    {[], state}
  end

  defp source(%{transport: :http} = playable, buffer_bytes) do
    child(:source, %HttpSource{
      uri: playable.uri,
      headers: playable.headers,
      buffer_bytes: buffer_bytes
    })
  end

  # A podcast episode is a file that `MyHiFi.Player.Download` writes as fast as the
  # network allows. The element reads it at the speed of the sound card, so the file
  # is the buffer and this transport needs none of the ring buffer of `HttpSource`.
  defp source(%{transport: :download} = playable, buffer_bytes) do
    child(:source, %FileSource{
      key: playable.key,
      uri: playable.uri,
      position_bytes: playable.position_bytes || 0,
      format: playable.format,
      buffer_bytes: buffer_bytes
    })
  end

  # `Membrane.HLS.Source` reads the media playlist again and again, and it returns
  # the bytes of each segment. The playlist therefore is the buffer, and this
  # source needs none of its own.
  defp source(%{transport: :hls} = playable, _buffer_bytes) do
    child(:source, %Membrane.HLS.Source{
      storage: Hls.Storage.new(),
      media_playlist_uri: URI.parse(playable.uri),
      stream_format: hls_format(playable.container)
    })
  end

  defp hls_format(:mpeg_ts), do: %Membrane.HLS.Format.MPEG{codecs: []}
  defp hls_format(:none), do: %Membrane.HLS.Format.PackedAudio{}

  # The demultiplexer waits for the tables of the transport stream, and it then
  # gives each stream on a pad of its own. `stream_category: :audio` asks for the
  # first audio stream, so this pipeline needs no knowledge of the numbers inside.
  defp demuxer(link, :mpeg_ts) do
    link
    |> child(:demuxer, Membrane.MPEG.TS.Demuxer)
    |> via_out(Pad.ref(:output, :audio), options: [stream_category: :audio])
  end

  defp demuxer(link, :none), do: link

  # An Ogg container needs no step here. The program that decodes it reads the
  # container itself. See `MyHiFi.Player.PortDecoder`.
  defp demuxer(link, :ogg), do: link

  # The FDK decoder takes AAC with an ADTS header, or a plain stream of bytes, and
  # it refuses the names that the HLS source and the demultiplexer give. Each
  # transport therefore needs its own step in front of the decoder.
  #
  # A packed audio segment starts with an ID3v2 tag. See
  # `MyHiFi.Player.PackedAudio`.
  defp adapter(link, %{transport: :hls, container: :none, format: :aac}) do
    link
    |> child(:packed_audio, MyHiFi.Player.PackedAudio)
    |> child(:parser, %Membrane.AAC.Parser{out_encapsulation: :ADTS})
  end

  defp adapter(link, %{transport: :hls, container: :none}) do
    child(link, :packed_audio, MyHiFi.Player.PackedAudio)
  end

  # MPEG-TS carries AAC with an ADTS header, and the parser renames the stream for
  # the decoder.
  defp adapter(link, %{transport: :hls, container: :mpeg_ts, format: :aac}) do
    child(link, :parser, %Membrane.AAC.Parser{out_encapsulation: :ADTS})
  end

  # MAD takes any remote stream, and it stops on the timestamp that the
  # demultiplexer sets. See `MyHiFi.Player.MpegAudio`.
  defp adapter(link, %{transport: :hls, container: :mpeg_ts, format: :mp3}) do
    child(link, :mpeg_audio, MyHiFi.Player.MpegAudio)
  end

  # libfdk-aac keeps an input buffer of its own, and `aacDecoder_Fill` copies only
  # what fits. It reports the count of the bytes that it did not take, and its
  # manual then says to refill only when that count is zero.
  # `Membrane.AAC.FDK.Decoder` refills on each buffer and removes the rest, so a
  # large buffer loses most of its audio. The decoder then stops with `:unknown`,
  # the pipeline dies, and the player starts it again. That is why a station
  # played for a few seconds and then buffered again, for ever.
  #
  # This path needs no parser. The transport layer of libfdk-aac reads the ADTS
  # headers, and it finds the first frame of a stream that starts in the middle of
  # one. 3 of 9 New Zealand AAC stations start in the middle of a frame, and
  # `Membrane.AAC.Parser` stops with `:invalid_adts_header` on each of those.
  defp adapter(link, %{transport: :http, container: :none, format: :aac}) do
    via_in(link, :input, auto_demand_size: @fdk_input_bytes)
  end

  # **The queue of the decoder is the lead that the pipeline runs ahead of the sound.**
  # Membrane gives a pad that counts bytes 1500 * 400 = 600,000 of them by default,
  # and that is 37.5 seconds of a 128 kbit/s episode. A read on the board on
  # 2026-08-24 measured the reader 14 seconds in front of what a person heard, so a
  # resume began 14 seconds past the place that they stopped at.
  #
  # A live stream hid this. `MyHiFi.Player.HttpSource` keeps its own ring buffer for
  # the jitter of a network, so a small queue here costs it nothing.
  defp adapter(link, %{format: :mp3}) do
    via_in(link, :input, auto_demand_size: @mad_input_bytes)
  end

  # An Ogg stream needs nothing. `MyHiFi.Player.HttpSource` gives a
  # `Membrane.RemoteStream` with no content format, and a port decoder reads a pipe,
  # so it loses nothing.
  defp adapter(link, _playable), do: link

  # MAD gives 24-bit samples, and FDK gives 16-bit ones. The sink reads the format
  # from the stream and tells `aplay`, so neither one needs a resampler.
  defp decoder(link, %{format: :mp3}), do: child(link, :decoder, Membrane.MP3.MAD.Decoder)

  defp decoder(link, %{format: :aac}), do: child(link, :decoder, Membrane.AAC.FDK.Decoder)

  # Membrane has a decoder for neither Vorbis nor FLAC, so a program does the
  # work through a port. See `MyHiFi.Player.PortDecoder`. Each program reads the
  # Ogg container itself, so neither needs a demultiplexer.
  #
  # One program cannot serve both. `ogg123` names FLAC and Vorbis among its codecs,
  # and it reads a file to find out which one it is. Reading from a pipe it
  # cannot go back to the start, so it takes the first module that it tries and
  # stops on a FLAC stream.
  defp decoder(link, %{format: :vorbis}) do
    child(link, :decoder, %PortDecoder{command: "oggdec", arguments: ["--quiet", "-o", "-", "-"]})
  end

  defp decoder(link, %{container: :ogg, format: :flac}) do
    child(link, :decoder, %PortDecoder{
      command: "flac",
      arguments: ["--decode", "--ogg", "--stdout", "--silent", "-"]
    })
  end

  defp decoder(link, %{format: :flac}) do
    child(link, :decoder, %PortDecoder{
      command: "flac",
      arguments: ["--decode", "--stdout", "--silent", "-"]
    })
  end

  defp decoder(_link, playable) do
    raise ArgumentError, """
    No pipeline for #{inspect(playable.format)} in #{inspect(playable.container)}.

    This pipeline plays MP3, AAC, Ogg Vorbis, Ogg FLAC, and FLAC on its own.
    Opus and Speex need another program, and no New Zealand station sends either.
    """
  end
end
