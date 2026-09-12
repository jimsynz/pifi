defmodule MyHiFi.Player.AdtsFrameTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Player.AdtsFrame

  # AAC LC, 44100 Hz, stereo, no CRC, one raw data block, and a frame of 384 bytes.
  # The length of the frame is in the header, so the header and the count below
  # cannot disagree. See `header/1` of the module for each field.
  @header <<0xFF, 0xF1, 0x50, 0x80, 0x30, 0x1F, 0xFC>>
  @frame_bytes 384

  # One raw data block holds 1024 samples, so 44100 Hz gives 23.220 ms of audio.
  @frame_us 23_219
  @frame_ms 24

  setup do
    path = Path.join(System.tmp_dir!(), "adts_frame_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(path) end)
    {:ok, path: path}
  end

  defp open(path, contents) do
    File.write!(path, contents)
    {:ok, device} = :file.open(path, [:read, :binary, :raw])
    device
  end

  defp frames(count, payload \\ <<0>>) do
    body = byte_size(@header)
    fill = :binary.copy(payload, div(@frame_bytes - body, byte_size(payload)))
    frame = @header <> fill <> :binary.copy(<<0>>, @frame_bytes - body - byte_size(fill))

    :binary.copy(frame, count)
  end

  describe "boundary_before/3" do
    test "it gives a boundary of a frame and not a byte inside one", %{path: path} do
      device = open(path, frames(200))

      assert {:ok, byte} = AdtsFrame.boundary_before(device, 100 * @frame_bytes, 20_000)
      assert rem(byte, @frame_bytes) == 0
    end

    test "it steps back by the margin at least", %{path: path} do
      device = open(path, frames(200))
      from = 100 * @frame_bytes

      assert {:ok, byte} = AdtsFrame.boundary_before(device, from, 20_000)
      assert byte <= from - 20_000
    end

    test "it steps back no further than one frame past the margin", %{path: path} do
      device = open(path, frames(200))
      from = 100 * @frame_bytes

      assert {:ok, byte} = AdtsFrame.boundary_before(device, from, 20_000)
      assert byte > from - 20_000 - @frame_bytes
    end

    test "a margin that reaches the start of the file gives the first byte", %{path: path} do
      device = open(path, frames(20))

      assert {:ok, 0} = AdtsFrame.boundary_before(device, 1000, 20_000)
      assert {:ok, 0} = AdtsFrame.boundary_before(device, 500, 500)
    end

    # This is the trap that a scan backwards falls into. The payload holds the 12 bits
    # of a sync word, and no second frame agrees with it.
    test "the bits of a sync word inside the audio name no frame", %{path: path} do
      device = open(path, frames(200, <<0xFF, 0xF1>>))
      from = 100 * @frame_bytes

      assert {:ok, byte} = AdtsFrame.boundary_before(device, from, 20_000)
      assert rem(byte, @frame_bytes) == 0
    end

    test "bytes that hold no frame give an error", %{path: path} do
      device = open(path, :binary.copy(<<0>>, 40_000))

      assert {:error, :no_frame} = AdtsFrame.boundary_before(device, 30_000, 20_000)
    end
  end

  describe "boundary_at/3" do
    test "a byte on a boundary gives that byte", %{path: path} do
      device = open(path, frames(200))

      assert {:ok, byte} = AdtsFrame.boundary_at(device, 20 * @frame_bytes, 200 * @frame_bytes)
      assert byte == 20 * @frame_bytes
    end

    test "a byte inside a frame gives the boundary after it", %{path: path} do
      device = open(path, frames(200))

      assert {:ok, byte} =
               AdtsFrame.boundary_at(device, 20 * @frame_bytes + 100, 200 * @frame_bytes)

      assert byte == 21 * @frame_bytes
    end

    test "bytes that hold no frame give an error", %{path: path} do
      device = open(path, :binary.copy(<<0>>, 40_000))

      assert {:error, :no_frame} = AdtsFrame.boundary_at(device, 0, 40_000)
    end

    # **The longest ADTS frame is 8191 bytes, and a window is often shorter than
    # that.** It is shorter near the start of a file, and while a download holds its
    # first bytes. A reader that needed room for the longest frame found nothing in
    # such a window, and a backward skip to the start of a file then gave
    # `:no_frame`.
    test "a window shorter than the longest frame still holds its frames", %{path: path} do
      device = open(path, frames(200))

      assert {:ok, 0} = AdtsFrame.boundary_at(device, 0, 10 * @frame_bytes)
      assert {:ok, 0} = AdtsFrame.boundary_at(device, 0, 2 * @frame_bytes)
    end
  end

  describe "forward/4" do
    test "it walks whole frames and it never passes the time", %{path: path} do
      device = open(path, frames(400))

      assert {:ok, %{byte: byte, ms: ms}} = AdtsFrame.forward(device, 0, 1000, 400 * @frame_bytes)

      assert ms <= 1000
      assert ms > 1000 - @frame_ms
      assert rem(byte, @frame_bytes) == 0
    end

    test "the time that it gives is the sum of the frames", %{path: path} do
      device = open(path, frames(400))

      assert {:ok, %{byte: byte, ms: ms}} = AdtsFrame.forward(device, 0, 5000, 400 * @frame_bytes)

      frames = div(byte, @frame_bytes)
      assert ms == div(frames * @frame_us, 1000)
    end

    # A sum of whole milliseconds would lose seconds of a long walk. See the sum in
    # microseconds of `step/5`.
    test "a long walk holds its count", %{path: path} do
      device = open(path, frames(2000))

      assert {:ok, %{ms: ms}} = AdtsFrame.forward(device, 0, 30_000, 2000 * @frame_bytes)

      assert ms > 30_000 - @frame_ms
    end

    test "it stops at the limit", %{path: path} do
      device = open(path, frames(40))

      assert {:ok, %{byte: byte, ms: ms}} =
               AdtsFrame.forward(device, 0, 60_000, 40 * @frame_bytes)

      assert byte == 40 * @frame_bytes
      assert ms == div(40 * @frame_us, 1000)
    end

    test "a time of :infinity measures the span between two bytes", %{path: path} do
      device = open(path, frames(200))

      assert {:ok, %{byte: byte, ms: ms}} =
               AdtsFrame.forward(device, 10 * @frame_bytes, :infinity, 60 * @frame_bytes)

      assert byte == 60 * @frame_bytes
      assert ms == div(50 * @frame_us, 1000)
    end

    test "bytes that hold no frame give an error", %{path: path} do
      device = open(path, :binary.copy(<<0>>, 40_000))

      assert {:error, :no_frame} = AdtsFrame.forward(device, 0, 1000, 40_000)
    end
  end

  describe "bytes_of_ms/4" do
    test "it gives the bytes that hold a time", %{path: path} do
      device = open(path, frames(400))

      assert {:ok, bytes} = AdtsFrame.bytes_of_ms(device, 0, 1000, 400 * @frame_bytes)

      # A second is 43 frames of 384 bytes, and the walk lands inside one frame of it.
      assert_in_delta bytes, 16_524, @frame_bytes
    end

    test "a longer time scales from the same probe", %{path: path} do
      device = open(path, frames(2000))

      assert {:ok, one} = AdtsFrame.bytes_of_ms(device, 0, 1000, 2000 * @frame_bytes)
      assert {:ok, ten} = AdtsFrame.bytes_of_ms(device, 0, 10_000, 2000 * @frame_bytes)

      assert_in_delta ten, one * 10, @frame_bytes * 10
    end

    test "bytes that hold no frame give an error", %{path: path} do
      device = open(path, :binary.copy(<<0>>, 40_000))

      assert {:error, :no_frame} = AdtsFrame.bytes_of_ms(device, 0, 1000, 40_000)
    end
  end

  describe "a header that no decoder accepts" do
    # ADTS holds the layer at 00. The three other values name a layer of MPEG audio,
    # which is what `MyHiFi.Player.Mp3Frame` reads.
    test "a layer that is not 00 names no frame", %{path: path} do
      header = <<0xFF, 0xF3, 0x50, 0x80, 0x30, 0x1F, 0xFC>>
      frame = header <> :binary.copy(<<0>>, @frame_bytes - byte_size(header))
      device = open(path, :binary.copy(frame, 200))

      assert {:error, :no_frame} = AdtsFrame.boundary_at(device, 0, 200 * @frame_bytes)
    end

    # Index 13 and 14 are reserved, and 15 says that the rate is somewhere else.
    test "a sampling index that names no rate gives no frame", %{path: path} do
      header = <<0xFF, 0xF1, 0x7C, 0x80, 0x30, 0x1F, 0xFC>>
      frame = header <> :binary.copy(<<0>>, @frame_bytes - byte_size(header))
      device = open(path, :binary.copy(frame, 200))

      assert {:error, :no_frame} = AdtsFrame.boundary_at(device, 0, 200 * @frame_bytes)
    end
  end
end
