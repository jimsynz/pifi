defmodule PiFi.Player.SkipTest do
  use ExUnit.Case, async: true

  alias PiFi.Player.Skip

  # 128 kbit/s and 64 kbit/s, both 44100 Hz, MPEG1 Layer III, no padding. Both hold
  # 1152 samples, so each frame holds 26.122 ms of audio and the two hold a different
  # count of bytes. **That is the file that a bitrate cannot measure**: a skip that
  # scaled the bytes of one region would land twice as far in the other.
  @fast <<0xFF, 0xFB, 0x90, 0x00>>
  @fast_bytes 417
  @slow <<0xFF, 0xFB, 0x50, 0x00>>
  @slow_bytes 208
  @frame_us 26_122

  setup do
    path = Path.join(System.tmp_dir!(), "skip_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(path) end)
    {:ok, path: path}
  end

  defp open(path, contents) do
    File.write!(path, contents)
    {:ok, device} = :file.open(path, [:read, :binary, :raw])
    device
  end

  # AAC LC, 44100 Hz, stereo, one raw data block, and a frame of 384 bytes. The
  # strategy of this module holds no knowledge of a codec, so one file of ADTS proves
  # that it reads the other reader as well. See `PiFi.Player.AdtsFrameTest` for the
  # header itself.
  @adts <<0xFF, 0xF1, 0x50, 0x80, 0x30, 0x1F, 0xFC>>
  @adts_bytes 384
  @adts_us 23_219

  defp region(count, header, bytes) do
    :binary.copy(header <> :binary.copy(<<0>>, bytes - byte_size(header)), count)
  end

  defp ms_of(frames), do: div(frames * @frame_us, 1000)

  describe "a forward skip" do
    test "it moves the time that it names", %{path: path} do
      device = open(path, region(2000, @fast, @fast_bytes))
      limit = 2000 * @fast_bytes

      assert {:ok, %{byte: byte, ms: ms}} =
               Skip.place(device, 100 * @fast_bytes, 30_000, limit, :mp3)

      assert ms_of(div(byte, @fast_bytes) - 100) == ms
      assert_in_delta ms, 30_000, 30
    end

    test "it lands on a frame boundary", %{path: path} do
      device = open(path, region(2000, @fast, @fast_bytes))
      limit = 2000 * @fast_bytes

      assert {:ok, %{byte: byte}} =
               Skip.place(device, 100 * @fast_bytes + 200, 15_000, limit, :mp3)

      assert rem(byte, @fast_bytes) == 0
    end

    # A whole file then ends the stream, and a file that still grows waits for the
    # bytes. `PiFi.Player.FileSource` holds both.
    test "a skip past the end of the file stops at the end", %{path: path} do
      device = open(path, region(100, @fast, @fast_bytes))
      limit = 100 * @fast_bytes

      assert {:ok, %{byte: byte, ms: ms}} =
               Skip.place(device, 90 * @fast_bytes, 60_000, limit, :mp3)

      assert byte == limit
      assert ms == ms_of(10)
    end

    test "it reads no further than the limit", %{path: path} do
      device = open(path, region(2000, @fast, @fast_bytes))

      assert {:ok, %{byte: byte}} = Skip.place(device, 0, 60_000, 50 * @fast_bytes, :mp3)

      assert byte == 50 * @fast_bytes
    end
  end

  describe "a backward skip" do
    test "it moves the time that it names", %{path: path} do
      device = open(path, region(2000, @fast, @fast_bytes))
      limit = 2000 * @fast_bytes
      from = 1000 * @fast_bytes

      assert {:ok, %{byte: byte, ms: ms}} = Skip.place(device, from, -15_000, limit, :mp3)

      assert byte < from
      assert ms == -ms_of(1000 - div(byte, @fast_bytes))
      assert_in_delta ms, -15_000, 30
    end

    test "it lands on a frame boundary", %{path: path} do
      device = open(path, region(2000, @fast, @fast_bytes))
      limit = 2000 * @fast_bytes

      assert {:ok, %{byte: byte}} =
               Skip.place(device, 1000 * @fast_bytes + 100, -15_000, limit, :mp3)

      assert rem(byte, @fast_bytes) == 0
    end

    test "a skip past the start of the file stops at the start", %{path: path} do
      device = open(path, region(200, @fast, @fast_bytes))
      limit = 200 * @fast_bytes

      assert {:ok, %{byte: 0, ms: ms}} =
               Skip.place(device, 50 * @fast_bytes, -60_000, limit, :mp3)

      assert ms == -ms_of(50)
    end
  end

  # The measurement, and not the estimate. The candidate byte comes from the bitrate
  # at the current point, which is the slow region here, so the fast region before it
  # holds more time than the estimate expects.
  describe "a file of two bitrates" do
    setup %{path: path} do
      fast = region(1000, @fast, @fast_bytes)
      slow = region(1000, @slow, @slow_bytes)
      device = open(path, fast <> slow)

      {:ok, device: device, limit: byte_size(fast) + byte_size(slow), border: byte_size(fast)}
    end

    test "the time that a backward skip reports is the time of the byte that it gives",
         %{device: device, limit: limit, border: border} do
      from = border + 500 * @slow_bytes

      assert {:ok, %{byte: byte, ms: ms}} = Skip.place(device, from, -30_000, limit, :mp3)

      assert byte < border, "the skip must reach into the fast region"
      assert rem(byte, @fast_bytes) == 0
      assert -ms == ms_of(1000 - div(byte, @fast_bytes) + 500)
    end

    # A tenth of the request is what `PiFi.Player.Skip` promises, and this file
    # changes its bitrate by a factor of two in the middle. A real file changes less.
    test "a backward skip lands inside a tenth of the time that it names",
         %{device: device, limit: limit, border: border} do
      from = border + 500 * @slow_bytes

      assert {:ok, %{ms: ms}} = Skip.place(device, from, -30_000, limit, :mp3)

      assert_in_delta ms, -30_000, 3000
    end

    # The estimate of the candidate comes from the bitrate at the current point, and
    # here that point is 50 frames into the slow region. The fast region before it
    # therefore holds twice the bytes that the estimate expects, so the first
    # measurement lands about half way and the second one measures again.
    test "a measurement that lands far from the request measures a second time",
         %{device: device, limit: limit, border: border} do
      from = border + 50 * @slow_bytes

      assert {:ok, %{byte: byte, ms: ms}} = Skip.place(device, from, -30_000, limit, :mp3)

      assert -ms == ms_of(1000 - div(byte, @fast_bytes) + 50)
      assert_in_delta ms, -30_000, 3000
    end

    test "a forward skip crosses the border and measures both regions",
         %{device: device, limit: limit, border: border} do
      from = 900 * @fast_bytes

      assert {:ok, %{byte: byte, ms: ms}} = Skip.place(device, from, 20_000, limit, :mp3)

      assert byte > border, "the skip must reach into the slow region"
      assert ms == ms_of(100 + div(byte - border, @slow_bytes))
      assert_in_delta ms, 20_000, 30
    end
  end

  describe "a file that holds no frame" do
    test "a skip gives an error", %{path: path} do
      device = open(path, :binary.copy(<<0>>, 100_000))

      assert {:error, :no_frame} = Skip.place(device, 50_000, 15_000, 100_000, :mp3)
      assert {:error, :no_frame} = Skip.place(device, 50_000, -15_000, 100_000, :mp3)
    end
  end

  test "a skip of no time moves nothing", %{path: path} do
    device = open(path, region(200, @fast, @fast_bytes))

    assert {:ok, %{byte: 1000, ms: 0}} = Skip.place(device, 1000, 0, 200 * @fast_bytes, :mp3)
  end

  describe "a file of AAC" do
    test "a forward skip moves the time that it names", %{path: path} do
      device = open(path, region(2000, @adts, @adts_bytes))
      limit = 2000 * @adts_bytes

      assert {:ok, %{byte: byte, ms: ms}} =
               Skip.place(device, 100 * @adts_bytes, 30_000, limit, :aac)

      assert byte > 100 * @adts_bytes
      assert rem(byte, @adts_bytes) == 0
      assert_in_delta ms, 30_000, div(@adts_us, 1000) + 1
    end

    test "a backward skip moves the time that it names", %{path: path} do
      device = open(path, region(2000, @adts, @adts_bytes))
      limit = 2000 * @adts_bytes

      assert {:ok, %{byte: byte, ms: ms}} =
               Skip.place(device, 1800 * @adts_bytes, -30_000, limit, :aac)

      assert byte < 1800 * @adts_bytes
      assert rem(byte, @adts_bytes) == 0
      assert_in_delta ms, -30_000, div(@adts_us, 1000) + 1
    end

    test "a skip past the start of the file stops at the start", %{path: path} do
      device = open(path, region(200, @adts, @adts_bytes))
      limit = 200 * @adts_bytes

      assert {:ok, %{byte: 0, ms: ms}} =
               Skip.place(device, 10 * @adts_bytes, -60_000, limit, :aac)

      assert_in_delta ms, -div(10 * @adts_us, 1000), 1
    end
  end

  describe "a codec that this firmware reads no frame of" do
    test "it gives an error and it moves nothing", %{path: path} do
      device = open(path, region(200, @adts, @adts_bytes))

      assert {:error, {:no_frames, :vorbis}} =
               Skip.place(device, 100 * @adts_bytes, 30_000, 200 * @adts_bytes, :vorbis)
    end

    # A skip of no time answers before it reads anything, so it needs no reader.
    test "a skip of no time still moves nothing", %{path: path} do
      device = open(path, region(200, @adts, @adts_bytes))

      assert {:ok, %{byte: 500, ms: 0}} = Skip.place(device, 500, 0, 200 * @adts_bytes, :vorbis)
    end
  end
end
