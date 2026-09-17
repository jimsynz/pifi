defmodule PiFi.Player.FlacFrameTest do
  @moduledoc """
  The reader of FLAC frames.

  **The headers of `describe "a header that a real encoder wrote"` are real bytes.**
  `flac` 1.5.0 wrote them on 2026-09-11, and `flac -a` named the frame number and the
  block size of each one. They anchor this file: the helpers below build a file of
  their own, and a fault shared by a helper and the module would otherwise pass.
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias PiFi.Player.FlacFrame

  @rate 44_100
  @block 4608
  @frame_bytes 1288
  @max_frame 1311

  setup do
    path = Path.join(System.tmp_dir!(), "flac_frame_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(path) end)
    {:ok, path: path}
  end

  defp open(path, contents) do
    File.write!(path, contents)
    {:ok, device} = :file.open(path, [:read, :binary, :raw])
    device
  end

  # A `fLaC` marker and one STREAMINFO block, which is the shortest metadata that a
  # file can carry. The audio then begins at byte 42.
  defp metadata(samples) do
    streaminfo =
      <<@block::16, @block::16, 0::24, @max_frame::24, @rate::20, 1::3, 15::5, samples::36,
        0::128>>

    "fLaC" <> <<1::1, 0::7, 34::24>> <> streaminfo
  end

  defp audio_start, do: byte_size(metadata(0))

  # The header of one frame, with a fixed block size, 44100 Hz, stereo and 16 bits.
  # The CRC is what makes a header real, so a helper that builds a file must compute
  # it. See the moduledoc for what keeps this honest.
  defp header(number) do
    body = <<0xFF, 0xF8, 0x59, 0x88>> <> coded(number)

    body <> <<crc8(body)>>
  end

  defp coded(number) when number < 0x80, do: <<number>>

  defp coded(number) when number < 0x800 do
    <<0xC0 ||| number >>> 6, 0x80 ||| (number &&& 0x3F)>>
  end

  defp coded(number) do
    <<0xE0 ||| number >>> 12, 0x80 ||| (number >>> 6 &&& 0x3F), 0x80 ||| (number &&& 0x3F)>>
  end

  defp crc8(bytes), do: crc8(bytes, 0)

  defp crc8(<<>>, crc), do: crc
  defp crc8(<<byte, rest::binary>>, crc), do: crc8(rest, shifted(bxor(crc, byte), 8))

  defp shifted(crc, 0), do: crc

  defp shifted(crc, steps) when (crc &&& 0x80) == 0, do: shifted(crc <<< 1 &&& 0xFF, steps - 1)

  defp shifted(crc, steps), do: shifted(bxor(crc <<< 1, 0x07) &&& 0xFF, steps - 1)

  # A file of `count` frames, each one padded to the same length. The padding holds
  # `0x00`, which carries no sync word.
  defp file(count, payload \\ <<0>>) do
    frames =
      for number <- 0..(count - 1), into: <<>> do
        head = header(number)
        fill = :binary.copy(payload, div(@frame_bytes - byte_size(head), byte_size(payload)))

        head <> fill <> :binary.copy(<<0>>, @frame_bytes - byte_size(head) - byte_size(fill))
      end

    metadata(count * @block) <> frames
  end

  defp offset_of(number), do: audio_start() + number * @frame_bytes
  defp size_of(count), do: audio_start() + count * @frame_bytes
  defp ms_of(frames), do: div(frames * @block * 1000, @rate)

  describe "stream_info/1" do
    test "it reads the rate, the block size and where the audio begins", %{path: path} do
      device = open(path, file(50))

      assert {:ok, info} = FlacFrame.stream_info(device)
      assert info.rate == @rate
      assert info.block == @block
      assert info.channels == 2
      assert info.samples == 50 * @block
      assert info.audio_start == audio_start()
    end

    test "a file that carries no fLaC marker gives an error", %{path: path} do
      device = open(path, :binary.copy(<<0>>, 10_000))

      assert {:error, :not_flac} = FlacFrame.stream_info(device)
    end
  end

  describe "header/1" do
    # **A stream that begins in the middle carries no STREAMINFO**, and `flac` then
    # wrote a WAV header of `channels: 0` and `bits: 0` that
    # `PiFi.Player.PortDecoder` stopped on. These 42 bytes are what answer it.
    test "it gives the marker and one STREAMINFO block", %{path: path} do
      device = open(path, file(50))

      assert {:ok, header} = FlacFrame.header(device)
      assert byte_size(header) == 42
      assert <<"fLaC", rest::binary>> = header
      assert <<last::1, type::7, length::24, _streaminfo::binary>> = rest
      assert {last, type, length} == {1, 0, 34}
    end

    # The block of the file may say that another block follows it, and a decoder that
    # read that would wait for a block that this never sends.
    test "it says that no other metadata block follows", %{path: path} do
      # `metadata/1` writes the flag as 1 already, so this writes a file whose
      # STREAMINFO says that more blocks follow.
      streaminfo =
        <<@block::16, @block::16, 0::24, @max_frame::24, @rate::20, 1::3, 15::5, 0::36, 0::128>>

      device =
        open(path, "fLaC" <> <<0::1, 0::7, 34::24>> <> streaminfo <> :binary.copy(<<0>>, 100))

      assert {:ok, <<"fLaC", 1::1, 0::7, 34::24, _rest::binary>>} = FlacFrame.header(device)
    end

    test "a file that carries no fLaC marker gives an error", %{path: path} do
      device = open(path, :binary.copy(<<0>>, 100))

      assert {:error, :not_flac} = FlacFrame.header(device)
    end
  end

  describe "frame_at/4" do
    setup %{path: path} do
      device = open(path, file(200))
      {:ok, info} = FlacFrame.stream_info(device)
      %{device: device, info: info}
    end

    test "a byte on a boundary gives that byte", %{device: device, info: info} do
      assert {:ok, frame} = FlacFrame.frame_at(device, offset_of(20), size_of(200), info)
      assert frame.byte == offset_of(20)
      assert frame.sample == 20 * @block
      assert frame.rate == @rate
    end

    # **A byte inside a frame must never name that frame.** A stream that begins one
    # byte past a boundary decodes nothing at all. See the module documentation.
    test "a byte inside a frame gives the frame after it", %{device: device, info: info} do
      assert {:ok, frame} = FlacFrame.frame_at(device, offset_of(20) + 1, size_of(200), info)
      assert frame.byte == offset_of(21)
    end

    test "bytes that hold no frame give an error", %{path: path, info: info} do
      device = open(path, metadata(0) <> :binary.copy(<<0>>, 40_000))

      assert {:error, :no_frame} = FlacFrame.frame_at(device, audio_start(), 40_000, info)
    end

    # The CRC is what tells a real header from the bits of a sync word inside audio.
    test "a sync word inside the audio names no frame", %{path: path} do
      device = open(path, file(200, <<0xFF, 0xF8>>))
      {:ok, info} = FlacFrame.stream_info(device)

      assert {:ok, frame} = FlacFrame.frame_at(device, offset_of(20) + 4, size_of(200), info)
      assert frame.byte == offset_of(21)
    end
  end

  describe "place/4" do
    setup %{path: path} do
      device = open(path, file(400))
      %{device: device, limit: size_of(400)}
    end

    test "a forward skip lands on a frame boundary", context do
      %{device: device, limit: limit} = context

      assert {:ok, place} = FlacFrame.place(device, offset_of(10), 30_000, limit)
      assert rem(place.byte - audio_start(), @frame_bytes) == 0
      assert place.byte > offset_of(10)
    end

    # **The time is exact.** Each header names the sample that its frame begins at, so
    # this reports a difference and never a measurement.
    test "a forward skip reports the time that it moved", context do
      %{device: device, limit: limit} = context

      assert {:ok, place} = FlacFrame.place(device, offset_of(10), 30_000, limit)

      frames = div(place.byte - offset_of(10), @frame_bytes)
      assert place.ms == ms_of(frames)
      assert_in_delta place.ms, 30_000, ms_of(1)
    end

    test "a backward skip reports a negative time", context do
      %{device: device, limit: limit} = context

      assert {:ok, place} = FlacFrame.place(device, offset_of(300), -30_000, limit)

      assert place.byte < offset_of(300)
      assert rem(place.byte - audio_start(), @frame_bytes) == 0
      assert_in_delta place.ms, -30_000, ms_of(1)
    end

    test "a skip of no time moves nothing", context do
      %{device: device, limit: limit} = context

      assert {:ok, %{byte: 5000, ms: 0}} = FlacFrame.place(device, 5000, 0, limit)
    end

    test "a skip past the start of the file stops at the first frame", context do
      %{device: device, limit: limit} = context

      assert {:ok, place} = FlacFrame.place(device, offset_of(10), -600_000, limit)

      assert place.byte == audio_start()
      assert place.ms == -ms_of(10)
    end

    test "a skip past the end of the file stops at the last frame", context do
      %{device: device, limit: limit} = context

      assert {:ok, place} = FlacFrame.place(device, offset_of(10), 600_000, limit)

      assert place.byte == offset_of(399)
      assert place.ms == ms_of(389)
    end

    test "a file that carries no frame gives an error", %{path: path} do
      device = open(path, metadata(0) <> :binary.copy(<<0>>, 40_000))

      assert {:error, :no_frame} = FlacFrame.place(device, audio_start(), 30_000, 40_000)
    end
  end

  describe "boundary_before/3" do
    setup %{path: path} do
      device = open(path, file(400))
      %{device: device}
    end

    test "it gives a frame boundary and not a byte inside one", %{device: device} do
      assert {:ok, byte} = FlacFrame.boundary_before(device, offset_of(300), 96 * 1024)
      assert rem(byte - audio_start(), @frame_bytes) == 0
    end

    test "it steps back by about the margin", %{device: device} do
      from = offset_of(300)

      assert {:ok, byte} = FlacFrame.boundary_before(device, from, 96 * 1024)
      assert byte <= from - 96 * 1024 + @frame_bytes
      assert byte >= from - 96 * 1024
    end

    # Byte 0 would send the `fLaC` marker to a decoder that is already running. The
    # first frame of the audio is what a resume needs.
    test "a margin that reaches the start gives the first frame", %{device: device} do
      assert {:ok, byte} = FlacFrame.boundary_before(device, offset_of(2), 96 * 1024)
      assert byte == audio_start()
    end
  end

  describe "a header that a real encoder wrote" do
    # `flac` 1.5.0 wrote a 30 second tone on 2026-09-11, and `flac -a` named the frame
    # number of each of these. The last one is the case that a wrong reader gets
    # wrong: it holds 504 samples and not 4608, and its number is still 287.
    @real [
      {<<0xFF, 0xF8, 0x59, 0x88, 0x00, 0x8A>>, 0},
      {<<0xFF, 0xF8, 0x59, 0x88, 0x01, 0x8D>>, 1},
      {<<0xFF, 0xF8, 0x59, 0x88, 0x32, 0x14>>, 50},
      {<<0xFF, 0xF8, 0x59, 0x88, 0x64, 0xB1>>, 100},
      {<<0xFF, 0xF8, 0x59, 0x88, 0x7F, 0xF0>>, 127},
      {<<0xFF, 0xF8, 0x59, 0x88, 0xC2, 0x80, 0xF1>>, 128},
      {<<0xFF, 0xF8, 0x79, 0x88, 0xC4, 0x9F, 0x01, 0xF7, 0x75>>, 287}
    ]

    for {bytes, number} <- @real do
      test "the header of frame #{number} names sample #{number * @block}", %{path: path} do
        bytes = unquote(bytes)
        number = unquote(number)

        device = open(path, metadata(0) <> bytes <> :binary.copy(<<0>>, 4000))
        {:ok, info} = FlacFrame.stream_info(device)

        assert {:ok, frame} = FlacFrame.frame_at(device, audio_start(), 4100, info)
        assert frame.byte == audio_start()
        assert frame.sample == number * @block
        assert frame.rate == @rate
      end
    end

    # One bit of the CRC is enough, and this is what keeps a skip from landing inside
    # a frame.
    test "a header whose CRC is wrong names no frame", %{path: path} do
      device = open(path, metadata(0) <> <<0xFF, 0xF8, 0x59, 0x88, 0x00, 0x8B>>)
      {:ok, info} = FlacFrame.stream_info(device)

      assert {:error, :no_frame} = FlacFrame.frame_at(device, audio_start(), 4100, info)
    end
  end
end
