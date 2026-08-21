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

  @impl true
  def handle_init(_ctx, options) do
    spec =
      child(:source, %HttpSource{
        uri: options.uri,
        headers: options.headers,
        buffer_bytes: options.buffer_bytes
      })
      |> decoder(options.format)
      |> child(:sink, options.sink)

    {[spec: spec], %{parent: options.parent}}
  end

  @impl true
  def handle_child_notification(:playing, :source, _ctx, state) do
    send(state.parent, {:pipeline_playing, self()})
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

    #8 covers MP3 and AAC over a plain HTTP stream. #10 covers HLS.
    """
  end
end
