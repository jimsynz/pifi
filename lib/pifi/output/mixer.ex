defmodule PiFi.Output.Mixer do
  @moduledoc """
  Sums two streams of raw audio, with a gain that moves across the buffer.

  This is the arithmetic of a crossfade and nothing else: no process, no state, no
  knowledge of where the bytes came from. `PiFi.Output.APlayPort` holds the two
  streams and calls this for each pair of buffers that it can pair up.

  ## Why the gain is a pair and not a number

  A fade moves the gain every sample, and a caller works in buffers. So `mix/4` takes
  the gain at the first frame and the gain at the last one, and walks between them.
  The caller knows how far through the fade it is and gives the two numbers; this
  needs to know nothing about the length of the fade.

  **The measurement that decided this lives in issue 167.** A ramped mix of 44100 Hz
  stereo `s24le` costs 2.32% of one core of an AMD Ryzen 5 4500U with integer
  arithmetic and 3.22% with floats, which is why this counts in integers: a
  16 bit fractional gain and a shift, and no `round/1` anywhere.

  ## The formats it takes

  The little-endian signed ones that the decoders of this firmware produce, and
  `:f32le`. `supported?/1` answers for a format, and a caller that meets `false` must
  not fade: the alternative is mixing two streams as though they held a shape that
  they do not, which is noise at full volume into somebody's stereo.

  Both streams must already hold the same format. `PiFi.Output.APlayPort` gets that
  for free, because it keys the program on the arguments of `aplay` and a stream of
  another shape opens another program.
  """

  import Bitwise

  @one 65_536

  @typedoc "A sample format that this can mix."
  @type format :: :s16le | :s24le | :s32le | :f32le

  @doc """
  Whether two streams of this format can be mixed.

      iex> PiFi.Output.Mixer.supported?(:s24le)
      true

      iex> PiFi.Output.Mixer.supported?(:s16be)
      false
  """
  @spec supported?(atom()) :: boolean()
  def supported?(format), do: format in [:s16le, :s24le, :s32le, :f32le]

  @doc """
  How many bytes one sample of this format takes.

      iex> PiFi.Output.Mixer.sample_bytes(:s24le)
      3
  """
  @spec sample_bytes(format()) :: pos_integer()
  def sample_bytes(:s16le), do: 2
  def sample_bytes(:s24le), do: 3
  def sample_bytes(:s32le), do: 4
  def sample_bytes(:f32le), do: 4

  @doc """
  Sum two buffers, taking `a` down from `from` and `b` up from `1 - from`.

  `from` and `to` are the gain of `a` at the first sample and at the last one, each
  between 0.0 and 1.0. `b` takes the rest, so the two always sum to one and a fade
  holds its loudness across the middle.

  **The two buffers must be the same length**, and that length must be a whole number
  of samples. `PiFi.Output.APlayPort` pairs them to the shorter of the two and keeps
  the remainder, so this never has to decide what a partial sample means.

      iex> silence = <<0, 0, 0, 0, 0, 0>>
      iex> PiFi.Output.Mixer.mix(silence, silence, :s24le, {1.0, 0.0})
      <<0, 0, 0, 0, 0, 0>>
  """
  @spec mix(binary(), binary(), format(), {float(), float()}) :: binary()
  def mix(a, b, format, {from, to}) when byte_size(a) == byte_size(b) do
    width = sample_bytes(format)
    count = div(byte_size(a), width)

    walk(a, b, format, gain(from), step(from, to, count), [])
  end

  # The gain moves by the same amount for each sample, and a buffer of one sample
  # moves not at all.
  defp step(_from, _to, count) when count <= 1, do: 0
  defp step(from, to, count), do: div(gain(to) - gain(from), count - 1)

  defp gain(value), do: trunc(value * @one)

  defp walk(<<>>, <<>>, _format, _g, _step, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp walk(a, b, :s24le, g, step, acc) do
    <<xa::little-signed-24, rest_a::binary>> = a
    <<xb::little-signed-24, rest_b::binary>> = b

    v = clamp((xa * g + xb * (@one - g)) >>> 16, 8_388_607, -8_388_608)

    walk(rest_a, rest_b, :s24le, g + step, step, [<<v::little-signed-24>> | acc])
  end

  defp walk(a, b, :s16le, g, step, acc) do
    <<xa::little-signed-16, rest_a::binary>> = a
    <<xb::little-signed-16, rest_b::binary>> = b

    v = clamp((xa * g + xb * (@one - g)) >>> 16, 32_767, -32_768)

    walk(rest_a, rest_b, :s16le, g + step, step, [<<v::little-signed-16>> | acc])
  end

  defp walk(a, b, :s32le, g, step, acc) do
    <<xa::little-signed-32, rest_a::binary>> = a
    <<xb::little-signed-32, rest_b::binary>> = b

    v = clamp((xa * g + xb * (@one - g)) >>> 16, 2_147_483_647, -2_147_483_648)

    walk(rest_a, rest_b, :s32le, g + step, step, [<<v::little-signed-32>> | acc])
  end

  # A float stream carries no integer range to clip to, and a sum of two that each sit
  # inside -1.0..1.0 cannot leave it while the gains sum to one.
  defp walk(a, b, :f32le, g, step, acc) do
    <<xa::little-float-32, rest_a::binary>> = a
    <<xb::little-float-32, rest_b::binary>> = b

    v = xa * (g / @one) + xb * (1.0 - g / @one)

    walk(rest_a, rest_b, :f32le, g + step, step, [<<v::little-float-32>> | acc])
  end

  defp clamp(v, high, _low) when v > high, do: high
  defp clamp(v, _high, low) when v < low, do: low
  defp clamp(v, _high, _low), do: v
end
