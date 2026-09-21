defmodule PiFi.Output.MixerTest do
  use ExUnit.Case, async: true

  doctest PiFi.Output.Mixer, import: true

  alias PiFi.Output.Mixer

  defp s24(values), do: for(v <- values, into: <<>>, do: <<v::little-signed-24>>)
  defp from_s24(bin), do: for(<<v::little-signed-24 <- bin>>, do: v)

  describe "which formats it takes" do
    # A caller that mixed an unsupported format would be reading one shape as another,
    # which is noise at full volume into somebody's stereo.
    test "the little-endian ones that the decoders here produce, and no others" do
      for good <- [:s16le, :s24le, :s32le, :f32le], do: assert(Mixer.supported?(good))
      for bad <- [:s16be, :s24be, :u8, :s8, :f32be], do: refute(Mixer.supported?(bad))
    end
  end

  describe "the gain across a buffer" do
    # The whole of a is the answer when a holds all the gain.
    test "a gain of one takes a and none of b" do
      a = s24([100, 200, 300])
      b = s24([-100, -200, -300])

      assert from_s24(Mixer.mix(a, b, :s24le, {1.0, 1.0})) == [100, 200, 300]
    end

    test "a gain of zero takes b and none of a" do
      a = s24([100, 200, 300])
      b = s24([-100, -200, -300])

      assert from_s24(Mixer.mix(a, b, :s24le, {0.0, 0.0})) == [-100, -200, -300]
    end

    # Half of each, which is what the middle of a fade sounds like.
    test "a gain of a half sums both at half" do
      a = s24([1000, 1000])
      b = s24([3000, 3000])

      assert from_s24(Mixer.mix(a, b, :s24le, {0.5, 0.5})) == [2000, 2000]
    end

    # **The point of the pair.** The caller works in buffers and the gain moves every
    # sample, so the first sample is all a and the last is all b.
    test "the gain walks from the first sample to the last" do
      a = s24([1000, 1000, 1000])
      b = s24([0, 0, 0])

      assert [first, middle, last] = from_s24(Mixer.mix(a, b, :s24le, {1.0, 0.0}))
      assert first == 1000
      assert_in_delta middle, 500, 2
      assert last == 0
    end

    test "a buffer of one sample takes the gain that it starts with" do
      assert from_s24(Mixer.mix(s24([800]), s24([0]), :s24le, {1.0, 0.0})) == [800]
    end
  end

  describe "the range of the samples" do
    # Two loud streams sum past what the format holds, and a wrap would be a crack.
    test "a sum that leaves the range is clipped and does not wrap" do
      a = s24([8_388_607, -8_388_608])
      b = s24([8_388_607, -8_388_608])

      assert from_s24(Mixer.mix(a, b, :s24le, {1.0, 1.0})) == [8_388_607, -8_388_608]
    end

    test "16 bit clips at its own range" do
      a = <<32_767::little-signed-16>>
      b = <<32_767::little-signed-16>>

      assert <<v::little-signed-16>> = Mixer.mix(a, b, :s16le, {1.0, 1.0})
      assert v == 32_767
    end
  end

  describe "the shape of what comes out" do
    test "it is as long as what went in, for each format" do
      for {format, width} <- [{:s16le, 2}, {:s24le, 3}, {:s32le, 4}, {:f32le, 4}] do
        a = :binary.copy(<<0>>, width * 8)
        b = :binary.copy(<<0>>, width * 8)

        assert byte_size(Mixer.mix(a, b, format, {1.0, 0.0})) == width * 8
      end
    end

    test "an empty pair gives nothing" do
      assert Mixer.mix(<<>>, <<>>, :s24le, {1.0, 0.0}) == <<>>
    end

    # A float stream carries no integer range, and two halves of a signal inside
    # -1.0..1.0 stay inside it.
    test "floats sum without clipping" do
      a = <<1.0::little-float-32>>
      b = <<-1.0::little-float-32>>

      assert <<v::little-float-32>> = Mixer.mix(a, b, :f32le, {0.5, 0.5})
      assert_in_delta v, 0.0, 0.0001
    end
  end
end
