defmodule MyHiFi.Player.Mp3Test do
  use ExUnit.Case, async: true

  import Bitwise, only: [>>>: 2, &&&: 2]

  alias MyHiFi.Player.Mp3

  doctest Mp3, import: true

  setup do
    Application.put_env(:my_hi_fi, Mp3, plug: {Req.Test, Mp3})
    on_exit(fn -> Application.delete_env(:my_hi_fi, Mp3) end)
    :ok
  end

  # A frame header of MPEG1 Layer III. The third byte holds the bitrate in its top
  # four bits, so 0x90 is index 9, which is 128 kbps.
  defp frame(bitrate_index, options \\ []) do
    version = Keyword.get(options, :version, 0xFB)

    <<0xFF, version, bitrate_index * 16, 0x00>>
  end

  # An ID3v2 tag holds its size in four bytes of seven bits each.
  defp id3(size) do
    <<"ID3", 3, 0, 0, size >>> 21 &&& 0x7F, size >>> 14 &&& 0x7F, size >>> 7 &&& 0x7F,
      size &&& 0x7F>> <> :binary.copy(<<0x41>>, size)
  end

  defp serve(binary) do
    Req.Test.stub(Mp3, fn conn ->
      ["bytes=" <> range] = Plug.Conn.get_req_header(conn, "range")
      [first, last] = String.split(range, "-")
      first = String.to_integer(first)

      if first >= byte_size(binary) do
        Plug.Conn.send_resp(conn, 416, "")
      else
        last = min(String.to_integer(last), byte_size(binary) - 1)
        Plug.Conn.send_resp(conn, 206, binary_part(binary, first, last - first + 1))
      end
    end)
  end

  defp padding(bytes), do: :binary.copy(<<0>>, bytes)

  describe "bitrate/1" do
    test "it reads the bitrate of audio that holds no tag" do
      serve(frame(9) <> padding(4092))

      assert {:ok, 128_000} = Mp3.bitrate("http://example.test/a.mp3")
    end

    test "it reads each bitrate of MPEG1 Layer III" do
      for {index, kilobits} <- [{1, 32}, {5, 64}, {9, 128}, {14, 320}] do
        serve(frame(index) <> padding(4092))

        assert {:ok, bitrate} = Mp3.bitrate("http://example.test/a.mp3")
        assert bitrate == kilobits * 1000
      end
    end

    test "it reads MPEG2 Layer III, which holds a table of its own" do
      # 0xF3 names MPEG2, where index 9 is 80 kbps and not 128.
      serve(frame(9, version: 0xF3) <> padding(4092))

      assert {:ok, 80_000} = Mp3.bitrate("http://example.test/a.mp3")
    end

    test "it steps over the tag at the start of the file" do
      # A podcast holds a picture in that tag, so the audio starts far into the
      # file. 40 KB is ordinary.
      serve(id3(40_000) <> frame(9) <> padding(4092))

      assert {:ok, 128_000} = Mp3.bitrate("http://example.test/a.mp3")
    end

    test "it finds a frame that does not start at the first byte of the audio" do
      serve(padding(500) <> frame(9) <> padding(4092))

      assert {:ok, 128_000} = Mp3.bitrate("http://example.test/a.mp3")
    end

    test "it steps over a pattern that looks like a header and is not" do
      # 0xFF 0xFB with a bitrate index of 15 is not a frame, and neither is a
      # bitrate index of 0. A real frame follows both.
      serve(<<0xFF, 0xFB, 0xF0, 0x00, 0xFF, 0xFB, 0x00, 0x00>> <> frame(9) <> padding(4092))

      assert {:ok, 128_000} = Mp3.bitrate("http://example.test/a.mp3")
    end

    test "audio that holds no frame gives an error" do
      serve(padding(4096))

      assert {:error, :no_frame} = Mp3.bitrate("http://example.test/a.mp3")
    end

    test "an answer that is not audio gives its status" do
      Req.Test.stub(Mp3, fn conn -> Plug.Conn.send_resp(conn, 404, "no") end)

      assert {:error, {:unexpected_status, 404}} = Mp3.bitrate("http://example.test/a.mp3")
    end

    test "a fault of the network gives the reason of `Req`" do
      Req.Test.stub(Mp3, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Req.TransportError{}} = Mp3.bitrate("http://example.test/a.mp3")
    end
  end

  describe "offset/2" do
    test "it gives the byte offset of a point in time" do
      serve(frame(9) <> padding(4092))

      # 250 seconds of 128 kbps is 4,000,000 bytes.
      assert {:ok, 4_000_000} = Mp3.offset("http://example.test/a.mp3", 250_000)
    end

    test "it counts the tag as well, because a range names the file" do
      serve(id3(40_000) <> frame(9) <> padding(4092))

      # The tag holds 10 bytes of header and 40,000 of content.
      assert {:ok, offset} = Mp3.offset("http://example.test/a.mp3", 250_000)
      assert offset == 40_010 + 4_000_000
    end

    test "the start of a track is the start of the audio" do
      serve(id3(1000) <> frame(9) <> padding(4092))

      assert {:ok, 1010} = Mp3.offset("http://example.test/a.mp3", 0)
    end

    test "audio that holds no frame gives an error and no offset" do
      serve(padding(4096))

      assert {:error, :no_frame} = Mp3.offset("http://example.test/a.mp3", 250_000)
    end
  end

  describe "offset_of/2" do
    test "it is the bitrate and nothing else" do
      assert Mp3.offset_of(0, 128_000) == 0
      assert Mp3.offset_of(1000, 128_000) == 16_000
      assert Mp3.offset_of(250_000, 128_000) == 4_000_000
      assert Mp3.offset_of(250_000, 64_000) == 2_000_000
    end
  end
end
