defmodule PiFi.AirPlay.AlacTest do
  @moduledoc """
  The decoder, against audio something else made.

  **The fixture and the answer both come from ffmpeg.** A decoder checked against its own
  output agrees with itself and with nothing else, so `sine440.packets` was encoded by
  ffmpeg and the bytes below are what ffmpeg decodes it back to.

  To make it again:

      ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=0.25" \\
        -af "aformat=channel_layouts=stereo" -c:a alac short.m4a
      ffmpeg -i short.m4a -f s16le -acodec pcm_s16le short_ref.pcm

  The packets are the frames of the MP4, each behind its length as four big-endian
  bytes. `ffprobe -show_packets -show_entries packet=pos,size` gives where they are.
  """

  use ExUnit.Case, async: true

  doctest PiFi.AirPlay.Alac

  alias PiFi.AirPlay.Alac

  # frameLength 4096, 16 bits, 2 channels, 44100 Hz — what ffmpeg wrote into the
  # `alac` atom of the fixture.
  @config <<0, 0, 16, 0, 0, 16, 40, 10, 14, 2, 0, 0, 0, 0, 64, 4, 0, 21, 136, 128, 0, 0, 172, 68>>

  @samples 44_100
  @digest "b62b778352be6523642c0d1ed3318ce375d98191d0879e12c1201e6d7558734b"

  defp frames do
    "test/fixtures/alac/sine440.packets"
    |> File.read!()
    |> Stream.unfold(fn
      <<>> ->
        nil

      <<size::32, rest::binary>> ->
        <<frame::binary-size(^size), tail::binary>> = rest
        {frame, tail}
    end)
    |> Enum.to_list()
  end

  defp decoded do
    {:ok, decoder} = Alac.start(@config)

    Enum.map_join(frames(), fn frame ->
      {:ok, samples} = Alac.decode(decoder, frame)
      samples
    end)
  end

  defp left(pcm) do
    for <<value::little-signed-16, _right::little-signed-16 <- pcm>>, do: value
  end

  defp damage(frame) do
    flipped =
      Enum.reduce(1..Enum.random(1..24), frame, fn _flip, carrying ->
        at = Enum.random(0..(byte_size(carrying) - 1))
        <<head::binary-size(^at), byte, tail::binary>> = carrying

        <<head::binary, Bitwise.bxor(byte, Bitwise.bsl(1, Enum.random(0..7)))::8, tail::binary>>
      end)

    # A packet also arrives cut short, and a decoder that only ever met a full-length
    # frame reads past the end of a truncated one rather than running out of bits.
    case Enum.random(1..4) do
      1 -> binary_part(flipped, 0, Enum.random(1..byte_size(flipped)))
      _otherwise -> flipped
    end
  end

  defp crossings(values) do
    values
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [before, now] -> before < 0 != now < 0 end)
  end

  describe "decoding what ffmpeg encoded" do
    # **This is the whole of the verification.** Byte for byte against another
    # implementation of the same codec.
    test "gives back exactly what ffmpeg decodes it to" do
      pcm = decoded()

      assert byte_size(pcm) == @samples
      assert :crypto.hash(:sha256, pcm) |> Base.encode16(case: :lower) == @digest
    end

    test "a quarter second of stereo at 44100 is the length it should be" do
      # 0.25 s × 44100 × 2 channels × 2 bytes.
      assert byte_size(decoded()) == round(0.25 * 44_100) * 2 * 2
    end

    # **The hash alone would pass for a decoder that got the sample width or the channel
    # order wrong**, as long as it got them wrong the same way every run. Counting the
    # zero crossings of one channel reads the audio as audio: 440 Hz over a quarter of a
    # second is 110 cycles, so 220 crossings, and `ffmpeg` gives 219 for this fixture
    # because it starts at zero going up and ends mid-cycle. A decoder that read the
    # samples as 8 or 32 bits wide, or interleaved them the other way, lands nowhere near.
    test "the left channel really is a 440 Hz tone" do
      assert crossings(left(decoded())) == 219
    end

    # The tone is quiet: `volumedetect` reports a peak of -21.1 dB for the fixture, which
    # is 2896 of a possible 32767. The number is here so a decoder that returned silence,
    # or one that clipped, fails rather than passing a crossing count that silence would
    # also give.
    test "it reaches the level ffmpeg measured and no further" do
      assert decoded() |> left() |> Enum.map(&abs/1) |> Enum.max() == 2896
    end

    test "one decoder reads every frame of a stream" do
      {:ok, decoder} = Alac.start(@config)

      for frame <- frames() do
        assert {:ok, samples} = Alac.decode(decoder, frame)
        assert byte_size(samples) > 0
      end
    end

    # **A decoder belongs to a stream**, and two of them must not interfere. This is the
    # shape a second AirPlay session takes.
    test "two decoders at once give the same answer as one" do
      {:ok, one} = Alac.start(@config)
      {:ok, other} = Alac.start(@config)

      for frame <- frames() do
        assert {:ok, from_one} = Alac.decode(one, frame)
        assert {:ok, from_other} = Alac.decode(other, frame)
        assert from_one == from_other
      end
    end
  end

  describe "the configuration a sender sends" do
    test "is read into the parts it names" do
      assert {:ok, described} = Alac.describe(@config)

      assert described == %{
               frame_length: 4096,
               bit_depth: 16,
               channels: 2,
               sample_rate: 44_100
             }
    end

    # **Nothing guesses these.** A receiver that assumed 4096 frames of sixteen bits
    # would decode noise from a sender that said otherwise, and decode it confidently.
    test "anything that is not twenty-four bytes is refused" do
      for bytes <- [<<>>, <<0, 0, 16, 0>>, @config <> <<0>>, binary_part(@config, 0, 23)] do
        assert {:error, :bad_config} = Alac.describe(bytes)
        assert {:error, :bad_config} = Alac.start(bytes)
      end
    end
  end

  describe "the sample format" do
    test "names what the pipeline is told" do
      assert Alac.sample_format(16) == {:ok, :s16le}
      assert Alac.sample_format(24) == {:ok, :s24le}
    end

    # **The decoder writes samples for sixteen and twenty-four and for nothing else.**
    # The `switch` on `setinfo_sample_size` in `alac.c` falls through for twenty and
    # thirty-two, which leaves the output buffer untouched and still reports a length, so
    # a stream in either would play whatever that memory held last. These two are not
    # hypothetical depths the codec forbids — they are ones it allows and this decoder
    # does not write.
    test "a depth the decoder does not write is refused" do
      for depth <- [20, 32] do
        assert {:error, {:unsupported_depth, ^depth}} = Alac.sample_format(depth)
      end
    end

    test "a depth that is not a depth at all is refused" do
      assert {:error, {:unsupported_depth, 12}} = Alac.sample_format(12)
    end
  end

  describe "a configuration the decoder cannot play" do
    # **Refused before any audio arrives**, rather than after a sender has started
    # sending it. Nothing downstream gets a decoder that would hand it stale memory.
    test "is refused by start rather than accepted and decoded wrongly" do
      for depth <- [20, 32] do
        <<head::binary-size(5), _depth, tail::binary>> = @config

        assert {:error, {:unsupported_depth, ^depth}} =
                 Alac.start(head <> <<depth>> <> tail)
      end
    end

    test "a depth the decoder does write is accepted" do
      assert {:ok, _decoder} = Alac.start(@config)
    end

    # **The sender picks this number and every buffer in the decoder is sized from it.**
    # The decoder's own overflow checks multiply it in an `int`, so a large enough value
    # wraps them to a small number and they pass — which is how a frame ends up writing
    # past buffers that were allocated for a much shorter one.
    test "a frame length beyond what the decoder is built for is refused" do
      for length <- [0, 4097, 0xFFFFFFFF] do
        <<_old::32, tail::binary>> = @config

        assert {:error, {:unsupported_frame_length, ^length}} =
                 Alac.start(<<length::32>> <> tail)
      end
    end

    test "more channels than the decoder de-interleaves is refused" do
      for channels <- [0, 3, 255] do
        <<head::binary-size(9), _old, tail::binary>> = @config

        assert {:error, {:unsupported_channels, ^channels}} =
                 Alac.start(head <> <<channels>> <> tail)
      end
    end
  end

  # **These frames arrive on a UDP socket from anything on the network.** The decoder is
  # C, it runs inside the BEAM, and the version this vendored had no notion of how long
  # its input was — it read the bitstream until the bitstream said to stop, which walks
  # off the end of any frame that arrived corrupt. A crash here takes the whole firmware
  # with it, so the property that matters is that no packet can do anything but produce
  # bad audio.
  #
  # The bit flips start from real frames rather than from noise, because a random 200
  # bytes is rejected in the header and never reaches the decoding at all.
  describe "a frame that was damaged on the way" do
    test "never takes the decoder down, however it was damaged" do
      {:ok, decoder} = Alac.start(@config)
      real = frames()

      for _trial <- 1..2_000 do
        frame = damage(Enum.random(real))

        assert {:ok, samples} = Alac.decode(decoder, frame)
        assert byte_size(samples) <= 4096 * 2 * 4
      end
    end

    test "leaves the decoder able to read a real frame afterwards" do
      {:ok, decoder} = Alac.start(@config)
      [first | _rest] = frames()

      for _trial <- 1..500, do: Alac.decode(decoder, damage(first))

      assert {:ok, samples} = Alac.decode(decoder, first)
      assert byte_size(samples) > 0
    end

    # A short frame with many predictor coefficients is the shape that reached past the
    # working buffers, so the small frame lengths here are the point rather than padding.
    test "cannot reach past buffers sized for a short frame" do
      for length <- [1, 2, 3, 8, 64] do
        <<_old::32, tail::binary>> = @config
        {:ok, decoder} = Alac.start(<<length::32>> <> tail)

        for frame <- frames(), _trial <- 1..50 do
          assert {:ok, _samples} = Alac.decode(decoder, damage(frame))
        end
      end
    end
  end

  describe "a frame it cannot read" do
    # **This arrives on a UDP socket.** A packet that was corrupted on the way is a gap
    # in the audio, not a reason to end a session, so nothing here may take the caller
    # down with it.
    test "does not crash the caller" do
      {:ok, decoder} = Alac.start(@config)

      for frame <- [<<>>, <<0>>, :crypto.strong_rand_bytes(64), :binary.copy(<<255>>, 200)] do
        assert {:ok, _samples} = Alac.decode(decoder, frame)
      end
    end

    test "leaves the decoder able to read a real frame afterwards" do
      {:ok, decoder} = Alac.start(@config)
      [first | _rest] = frames()

      Alac.decode(decoder, :crypto.strong_rand_bytes(64))

      assert {:ok, samples} = Alac.decode(decoder, first)
      assert byte_size(samples) > 0
    end
  end
end
