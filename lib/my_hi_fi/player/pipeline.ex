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

  An HTTP source holds the ring buffer, so the compressed bytes wait there and the
  samples never do. An HLS source holds the segments of the playlist instead, and
  the playlist gives the buffer.

  The player starts one of these at a time, and it stops the old one first.
  """

  use Membrane.Pipeline

  alias MyHiFi.Player.Hls
  alias MyHiFi.Player.HttpSource

  # How many decoded buffers may wait at the sink. Membrane gives 400 by default,
  # and a buffer of MP3 samples is about 50 ms, so the default lets 20 seconds of
  # samples pile up in front of `aplay`. The sink writes to a port and the write
  # blocks, so the sink cannot read its own mailbox while it waits, and a request
  # to stop waits behind all of those samples. A person then presses stop and
  # hears several more seconds of music.
  #
  # Eight buffers is under half a second. ALSA holds another half second, and the
  # decoder runs much faster than the sound, so the sound stays smooth.
  @sink_queue_buffers 8

  @impl true
  def handle_init(_ctx, options) do
    playable = options.playable

    spec =
      playable
      |> source(options.buffer_bytes)
      |> demuxer(playable.container)
      |> adapter(playable)
      |> decoder(playable.format)
      |> via_in(:input, auto_demand_size: @sink_queue_buffers)
      |> child(:sink, options.sink)

    {[spec: spec], %{parent: options.parent}}
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

  # `Membrane.HLS.Source` reads the media playlist again and again, and it gives
  # the bytes of each segment. The playlist therefore holds the buffer, and this
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

  # A plain HTTP stream needs nothing: `MyHiFi.Player.HttpSource` gives a
  # `Membrane.RemoteStream` with no content format, and both decoders take that.
  defp adapter(link, _playable), do: link

  # MAD gives 24-bit samples, and FDK gives 16-bit ones. The sink reads the format
  # from the stream and tells `aplay`, so neither one needs a resampler.
  defp decoder(link, :mp3), do: child(link, :decoder, Membrane.MP3.MAD.Decoder)

  defp decoder(link, :aac), do: child(link, :decoder, Membrane.AAC.FDK.Decoder)

  defp decoder(_link, format) do
    raise ArgumentError, """
    No pipeline for #{inspect(format)}.

    This pipeline plays MP3 and AAC. FLAC and Ogg need a decoder that Membrane
    does not hold.
    """
  end
end
