defmodule MyHiFi.Player.Mp3FrameTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Player.Mp3Frame

  # 128 kbit/s, 44100 Hz, MPEG1 Layer III, no padding. This is the header that the
  # real episode of the board holds at its first byte, and the frame is
  # `div(144 * 128_000, 44_100)` = 417 bytes.
  @header <<0xFF, 0xFB, 0x90, 0x00>>
  @frame_bytes 417

  setup do
    path = Path.join(System.tmp_dir!(), "mp3_frame_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(path) end)
    {:ok, path: path}
  end

  defp open(path, contents) do
    File.write!(path, contents)
    {:ok, device} = :file.open(path, [:read, :binary, :raw])
    device
  end

  defp frames(count, payload \\ <<0>>) do
    body = :binary.copy(payload, div(@frame_bytes - 4, byte_size(payload)))
    frame = @header <> body <> :binary.copy(<<0>>, @frame_bytes - 4 - byte_size(body))

    :binary.copy(frame, count)
  end

  describe "boundary_before/3" do
    test "it gives a boundary of a frame and not a byte inside one", %{path: path} do
      device = open(path, frames(200))

      assert {:ok, byte} = Mp3Frame.boundary_before(device, 100 * @frame_bytes, 20_000)
      assert rem(byte, @frame_bytes) == 0
    end

    test "it steps back by the margin at least", %{path: path} do
      device = open(path, frames(200))
      from = 100 * @frame_bytes

      assert {:ok, byte} = Mp3Frame.boundary_before(device, from, 20_000)
      assert byte <= from - 20_000
    end

    test "it steps back no further than one frame past the margin", %{path: path} do
      device = open(path, frames(200))
      from = 100 * @frame_bytes

      assert {:ok, byte} = Mp3Frame.boundary_before(device, from, 20_000)
      assert byte > from - 20_000 - @frame_bytes
    end

    test "a margin that reaches the start of the file gives the first byte", %{path: path} do
      device = open(path, frames(20))

      assert {:ok, 0} = Mp3Frame.boundary_before(device, 1000, 20_000)
      assert {:ok, 0} = Mp3Frame.boundary_before(device, 500, 500)
    end

    # This is the trap that a scan backwards falls into, and the reason that MAD
    # skips a byte at a time. The payload holds the 11 bits of a sync word, and no
    # second frame agrees with it.
    test "the bits of a sync word inside the audio name no frame", %{path: path} do
      device = open(path, frames(200, <<0xFF, 0xFB>>))
      from = 100 * @frame_bytes

      assert {:ok, byte} = Mp3Frame.boundary_before(device, from, 20_000)
      assert rem(byte, @frame_bytes) == 0
    end

    test "bytes that hold no frame give an error", %{path: path} do
      device = open(path, :binary.copy(<<0>>, 40_000))

      assert {:error, :no_frame} = Mp3Frame.boundary_before(device, 30_000, 20_000)
    end

    test "it reads a window and not the file", %{path: path} do
      # A file of 8 MB, and a target far inside it. A walk of the whole file would
      # parse about 20,000 headers.
      device = open(path, frames(20_000))
      from = 19_000 * @frame_bytes

      assert {:ok, byte} = Mp3Frame.boundary_before(device, from, 20_000)
      assert rem(byte, @frame_bytes) == 0
      assert byte <= from - 20_000
    end
  end
end
