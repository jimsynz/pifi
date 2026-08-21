defmodule MyHiFi.Player.Pipeline do
  @moduledoc """
  The Membrane pipeline that plays one stream.

  Four stages: the HTTP source with its ring buffer, the decoder for the format,
  and the sink of the output. The source holds the buffer, so the compressed bytes
  wait there and the samples never do.

  The player starts one of these at a time, and it stops the old one first.
  """

  use Membrane.Pipeline

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
    spec =
      child(:source, %HttpSource{
        uri: options.uri,
        headers: options.headers,
        buffer_bytes: options.buffer_bytes
      })
      |> decoder(options.format)
      |> via_in(:input, auto_demand_size: @sink_queue_buffers)
      |> child(:sink, options.sink)

    {[spec: spec], %{parent: options.parent}}
  end

  @impl true
  def handle_child_notification(:playing, :source, _ctx, state) do
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

  # MAD gives 24-bit samples, and FDK gives 16-bit ones. The sink reads the format
  # from the stream and tells `aplay`, so neither one needs a resampler.
  defp decoder(link, :mp3), do: child(link, :decoder, Membrane.MP3.MAD.Decoder)

  defp decoder(link, :aac), do: child(link, :decoder, Membrane.AAC.FDK.Decoder)

  defp decoder(_link, format) do
    raise ArgumentError, """
    No pipeline for #{inspect(format)}.

    This pipeline plays MP3 and AAC over a plain HTTP stream. HLS needs a
    playlist reader in front of the decoder, and this firmware has none yet.
    """
  end
end
