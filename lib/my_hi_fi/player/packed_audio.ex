defmodule MyHiFi.Player.PackedAudio do
  @moduledoc """
  Prepares packed audio from an HLS playlist for a decoder.

  Section 3.4 of RFC 8216 says that a packed audio segment starts with an ID3v2
  tag, and that tag carries the timestamp of the segment. 14 of the 44 New Zealand
  HLS stations send packed AAC, so this covers a large part of them.

  A decoder reads the audio and not the tag. `Membrane.AAC.Parser` stops with
  `:invalid_adts_header` at the first tag, and a device then plays nothing. This
  element removes each tag and gives the audio alone.

  `membrane_hls_plugin` writes such a tag in `Membrane.HLS.AAC.Aggregator`, and it
  has nothing that reads one. That plugin packages a stream, and this firmware
  plays one.

  A tag arrives at the start of a segment, so this element looks for one at the
  start of the bytes only. The same three bytes inside the audio are audio, and
  this element leaves them alone.

  A segment can hold more than one tag, one after the other. The stations of one
  New Zealand network send two: the first carries the timestamp, and the second
  carries the title of the track. This element therefore looks again after each tag.
  """

  use Membrane.Filter

  def_input_pad(:input, accepted_format: _any, flow_control: :auto)

  def_output_pad(:output, accepted_format: %Membrane.RemoteStream{}, flow_control: :auto)

  @identifier "ID3"
  @header_bytes 10
  @footer_bytes 10

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{skip: non_neg_integer(), held: binary()}

    defstruct skip: 0, held: <<>>
  end

  @impl true
  def handle_init(_ctx, _options), do: {[], %State{}}

  # The decoder needs a stream with no content format. The HLS source names
  # `Membrane.HLS.Format.PackedAudio`, and the decoder refuses that name.
  @impl true
  def handle_stream_format(:input, _format, _ctx, state) do
    {[stream_format: {:output, %Membrane.RemoteStream{}}], state}
  end

  @impl true
  def handle_buffer(:input, %Membrane.Buffer{} = buffer, _ctx, %State{} = state) do
    {audio, held, skip} = consume(state.held <> buffer.payload, state.skip)
    state = %State{state | held: held, skip: skip}

    if audio == <<>> do
      {[], state}
    else
      {[buffer: {:output, %Membrane.Buffer{buffer | payload: audio}}], state}
    end
  end

  defp consume(data, skip) when skip > 0 do
    drop = min(skip, byte_size(data))
    <<_dropped::binary-size(^drop), rest::binary>> = data

    case skip - drop do
      # A segment can hold more than one tag, one after the other. The stations of
      # one network send two: the first carries the timestamp, and the second carries
      # the title of the track.
      0 -> consume(rest, 0)
      left -> {<<>>, <<>>, left}
    end
  end

  defp consume(
         <<@identifier, _version::binary-size(2), flags, size::binary-size(4), rest::binary>>,
         0
       ) do
    consume(rest, tag_bytes(size, flags) - @header_bytes)
  end

  # Fewer than ten bytes cannot say whether a tag starts here, so they wait for
  # the next buffer.
  defp consume(data, 0) when byte_size(data) < @header_bytes do
    if starts_tag?(data), do: {<<>>, data, 0}, else: {data, <<>>, 0}
  end

  defp consume(data, 0), do: {data, <<>>, 0}

  defp starts_tag?(data) do
    bytes = min(byte_size(data), byte_size(@identifier))

    binary_part(data, 0, bytes) == binary_part(@identifier, 0, bytes)
  end

  # The four size bytes each hold seven bits, and the highest bit of each one is
  # always zero. The size counts the bytes after the header.
  defp tag_bytes(<<0::1, a::7, 0::1, b::7, 0::1, c::7, 0::1, d::7>>, flags) do
    size = Bitwise.bsl(a, 21) + Bitwise.bsl(b, 14) + Bitwise.bsl(c, 7) + d

    @header_bytes + size + footer_bytes(flags)
  end

  # A tag with the footer flag carries ten more bytes at its end.
  defp footer_bytes(flags) when Bitwise.band(flags, 0x10) != 0, do: @footer_bytes
  defp footer_bytes(_flags), do: 0
end
