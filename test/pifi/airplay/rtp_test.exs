defmodule PiFi.AirPlay.RtpTest do
  use ExUnit.Case, async: true

  doctest PiFi.AirPlay.Rtp

  alias PiFi.AirPlay.Rtp
  alias PiFi.AirPlay.Rtp.Packet

  defp packet(options \\ []) do
    marker = Keyword.get(options, :marker, 0)
    count = Keyword.get(options, :csrc_count, 0)
    ext = Keyword.get(options, :extension, 0)
    payload = Keyword.get(options, :payload, "audio")
    tail = Keyword.get(options, :tail, <<>>)

    <<2::2, 0::1, ext::1, count::4, marker::1, 96::7, 7::16, 1000::32, 42::32>> <>
      tail <> payload
  end

  describe "reading the fixed header" do
    test "every field comes out where it went in" do
      assert {:ok, read} = Rtp.parse(packet())

      assert read.payload_type == 96
      assert read.sequence == 7
      assert read.timestamp == 1000
      assert read.ssrc == 42
      assert read.payload == "audio"
      refute read.marker?
      assert read.csrcs == []
      assert read.extension == nil
    end

    test "the marker bit" do
      assert {:ok, %Packet{marker?: true}} = Rtp.parse(packet(marker: 1))
    end

    test "a payload of nothing is a packet with no payload" do
      assert {:ok, %Packet{payload: ""}} = Rtp.parse(packet(payload: ""))
    end
  end

  # **A reader that assumed twelve bytes would hand the decoder the first few bytes of
  # its own payload** for any packet carrying either of these.
  describe "the parts that make the header longer" do
    test "contributing sources are read and removed from the payload" do
      raw = packet(csrc_count: 2, tail: <<111::32, 222::32>>)

      assert {:ok, read} = Rtp.parse(raw)
      assert read.csrcs == [111, 222]
      assert read.payload == "audio"
    end

    # The extension length counts 32-bit words and not bytes, which is the trap: a
    # reader taking it as bytes keeps a quarter of it and hands the rest on as audio.
    test "an extension length is words and not bytes" do
      raw = packet(extension: 1, tail: <<0xBEEF::16, 2::16, 1::32, 2::32>>)

      assert {:ok, read} = Rtp.parse(raw)
      assert read.extension == {0xBEEF, <<1::32, 2::32>>}
      assert read.payload == "audio"
    end

    test "both at once" do
      raw = packet(csrc_count: 1, extension: 1, tail: <<111::32, 0xBEEF::16, 1::16, 9::32>>)

      assert {:ok, read} = Rtp.parse(raw)
      assert read.csrcs == [111]
      assert read.extension == {0xBEEF, <<9::32>>}
      assert read.payload == "audio"
    end
  end

  # **These arrive on a UDP socket, so a packet can be anything at all.**
  describe "what it refuses" do
    test "a version that is not 2" do
      assert {:error, {:bad_version, 1}} = Rtp.parse(<<1::2, 0::6, 0::8, 0::16, 0::32, 0::32>>)
    end

    test "a packet too short to hold a header" do
      assert {:error, :truncated} = Rtp.parse(<<2::2, 0::6, 0::8>>)
    end

    test "a header claiming more contributing sources than are there" do
      raw = <<2::2, 0::1, 0::1, 4::4, 0::1, 96::7, 7::16, 1000::32, 42::32, 111::32>>

      assert {:error, :truncated} = Rtp.parse(raw)
    end

    test "an extension claiming more than is there" do
      raw = <<2::2, 0::1, 1::1, 0::4, 0::1, 96::7, 7::16, 1000::32, 42::32, 0xBEEF::16, 9::16>>

      assert {:error, :truncated} = Rtp.parse(raw)
    end

    test "an empty packet" do
      assert {:error, :truncated} = Rtp.parse(<<>>)
    end
  end

  # **Sixteen bits wrap every 65536 packets, about twenty-four minutes of audio.** A
  # comparison that asked which number was larger would decide the stream had run
  # backwards once every twenty-four minutes.
  describe "ordering across the wrap" do
    test "the ordinary case" do
      assert Rtp.later?(5, 4)
      refute Rtp.later?(4, 5)
    end

    test "a number is not later than itself" do
      refute Rtp.later?(7, 7)
    end

    test "zero follows sixty-five thousand five hundred and thirty-five" do
      assert Rtp.later?(0, 65_535)
      refute Rtp.later?(65_535, 0)
    end

    test "a whole sequence in order stays in order across the wrap" do
      numbers = Enum.map(65_530..65_540, &Integer.mod(&1, 65_536))

      for [one, two] <- Enum.chunk_every(numbers, 2, 1, :discard) do
        assert Rtp.later?(two, one), "#{two} should follow #{one}"
      end
    end

    # Halfway round the circle is where the shorter way stops being obvious, and it is
    # the boundary a naive comparison gets wrong in the other direction.
    test "the far side of the circle" do
      assert Rtp.later?(32_767, 0)
      refute Rtp.later?(32_768, 0)
    end

    test "the distance is the short way round" do
      assert Rtp.distance(10, 4) == 6
      assert Rtp.distance(2, 65_534) == 4
      assert Rtp.distance(4, 4) == 0
    end
  end
end
