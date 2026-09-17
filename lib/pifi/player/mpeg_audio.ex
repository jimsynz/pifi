defmodule PiFi.Player.MpegAudio do
  @moduledoc """
  Prepares MP3 from an MPEG-TS stream for the MAD decoder.

  It removes the timestamp of each buffer, and that keeps the decoder alive.

  `membrane_mp3_mad_plugin` has a fault. A live stream starts at any point, so
  the first frame that the decoder sees is almost always a part of a frame. The
  decoder calls that frame recoverable, it steps over the bytes, and it then asks
  for the time of the next frame. That step reads the stream format of its own
  output pad, and no format is there yet, because no frame decoded. The decoder
  stops with a `FunctionClauseError` in `Membrane.RawAudio.frames_to_time/3`.

  The step happens only for a buffer that carries a timestamp.
  `PiFi.Player.HttpSource` sets none, so a Shoutcast stream of MP3 plays.
  `Membrane.MPEG.TS.Demuxer` reads a timestamp from the PES header and sets one,
  so MP3 inside MPEG-TS stopped at the first frame. 8 of the 44 New Zealand HLS
  stations send that.

  Nothing after the decoder needs the timestamp. The sink writes the samples to
  `aplay`, and the player counts the time from its own clock.

  Remove this element when the plugin reads the format of the input pad, or when
  it stops asking for a time that it cannot know.
  """

  use Membrane.Filter

  def_input_pad(:input, accepted_format: _any, flow_control: :auto)

  def_output_pad(:output, accepted_format: %Membrane.RemoteStream{}, flow_control: :auto)

  @impl true
  def handle_init(_ctx, _options), do: {[], %{}}

  # MAD takes any remote stream, and it reads the format from the frames.
  @impl true
  def handle_stream_format(:input, _format, _ctx, state) do
    {[stream_format: {:output, %Membrane.RemoteStream{}}], state}
  end

  @impl true
  def handle_buffer(:input, %Membrane.Buffer{} = buffer, _ctx, state) do
    {[buffer: {:output, %Membrane.Buffer{buffer | pts: nil, dts: nil}}], state}
  end
end
