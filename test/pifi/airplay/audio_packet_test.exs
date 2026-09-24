defmodule PiFi.AirPlay.AudioPacketTest do
  @moduledoc """
  Taking the encryption off a packet of AirPlay audio.

  **The sender below is written from the layout rather than from the module it tests.**
  It reaches for `:crypto` directly instead of `PiFi.AirPlay.Cipher`, and it lays the
  bytes out from the offsets in Shairport Sync's `rtp.c` rather than from anything in
  `PiFi.AirPlay.AudioPacket`. A test that sealed with the same code that opens agrees
  with itself and with no telephone.

  The layout, from `decipher_player_put_packet`:

      0   1   2   3   4 5 6 7   8 9 10 11   12 …            … -8
      ┌───┬───┬───────┬───────┬───────────┬──────────────┬────────┐
      │v/p│ pt│  seq  │timestamp│   ssrc   │ ciphertext+tag│ nonce  │
      └───┴───┴───────┴───────┴───────────┴──────────────┴────────┘

  Bytes 4 to 11 are authenticated and not encrypted. The nonce is eight bytes and gets
  four zero bytes in front of it to make the twelve that ChaCha20-Poly1305 wants.
  """

  use ExUnit.Case, async: true

  alias PiFi.AirPlay.AudioPacket

  @payload_type 96

  defp key, do: :crypto.strong_rand_bytes(32)

  # A sender, written from the layout above.
  defp sent(audio, options) do
    key = Keyword.fetch!(options, :key)
    sequence = Keyword.get(options, :sequence, 1234)
    timestamp = Keyword.get(options, :timestamp, 555_666)
    ssrc = Keyword.get(options, :ssrc, 0xDEADBEEF)
    short = Keyword.get(options, :nonce, :crypto.strong_rand_bytes(8))

    aad = <<timestamp::32, ssrc::32>>

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :chacha20_poly1305,
        key,
        <<0::32, short::binary>>,
        audio,
        aad,
        true
      )

    <<2::2, 0::1, 0::1, 0::4, 0::1, @payload_type::7, sequence::16, timestamp::32, ssrc::32,
      ciphertext::binary, tag::binary, short::binary>>
  end

  describe "a packet a sender sealed" do
    test "gives back the audio that went in" do
      key = key()
      audio = "some alac frame bytes"

      assert {:ok, opened} = AudioPacket.open(sent(audio, key: key), key)
      assert opened.payload == audio
    end

    test "carries the sequence number and the timestamp through" do
      key = key()

      packet = sent("audio", key: key, sequence: 4_242, timestamp: 9_000_000)

      assert {:ok, opened} = AudioPacket.open(packet, key)
      assert opened.sequence == 4_242
      assert opened.timestamp == 9_000_000
    end

    # A session runs for hours and the sequence number is sixteen bits, so both ends of
    # its range arrive in ordinary use.
    test "reads the ends of the sequence range" do
      key = key()

      for sequence <- [0, 1, 65_534, 65_535] do
        packet = sent("audio", key: key, sequence: sequence)

        assert {:ok, %{sequence: ^sequence}} = AudioPacket.open(packet, key)
      end
    end

    test "an empty frame is still a packet" do
      key = key()

      assert {:ok, %{payload: <<>>}} = AudioPacket.open(sent(<<>>, key: key), key)
    end

    test "a full frame of stereo audio comes back whole" do
      key = key()
      audio = :crypto.strong_rand_bytes(1_408)

      assert {:ok, %{payload: ^audio}} = AudioPacket.open(sent(audio, key: key), key)
    end
  end

  describe "the nonce" do
    # **This is the detail with no clue in the packet.** A sender sends eight bytes and
    # the cipher wants twelve, and padding the wrong end fails every packet with a bad
    # tag and nothing to say why. The sender above pads the front, so a module that
    # padded the back would fail here rather than on a telephone.
    test "is padded at the front and not the back" do
      key = key()
      short = :crypto.strong_rand_bytes(8)

      packet = sent("audio", key: key, nonce: short)

      assert {:ok, _opened} = AudioPacket.open(packet, key)

      # The same bytes padded the other way is a different nonce, and must not open it.
      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :chacha20_poly1305,
          key,
          <<short::binary, 0::32>>,
          "audio",
          <<555_666::32, 0xDEADBEEF::32>>,
          true
        )

      wrong =
        <<2::2, 0::1, 0::1, 0::4, 0::1, @payload_type::7, 1234::16, 555_666::32, 0xDEADBEEF::32,
          ciphertext::binary, tag::binary, short::binary>>

      assert {:error, :bad_tag} = AudioPacket.open(wrong, key)
    end
  end

  describe "a packet that should not open" do
    # **These arrive on a UDP socket from anything on the network.** A packet that does
    # not authenticate is a gap in the audio, not a reason to end a session, and none of
    # these may raise.
    test "the wrong key is refused rather than giving noise" do
      packet = sent("audio", key: key())

      assert {:error, :bad_tag} = AudioPacket.open(packet, key())
    end

    test "audio that was altered on the way is refused" do
      key = key()
      packet = sent("some alac frame bytes", key: key)

      # Flip a bit in the ciphertext, which is well past the twelve-byte header.
      <<head::binary-size(20), byte, tail::binary>> = packet
      altered = <<head::binary, Bitwise.bxor(byte, 1)::8, tail::binary>>

      assert {:error, :bad_tag} = AudioPacket.open(altered, key)
    end

    # The timestamp and the source are authenticated even though they are not encrypted,
    # so changing either has to fail. That is the whole point of putting them in the
    # additional data.
    test "a header that was altered on the way is refused" do
      key = key()
      packet = sent("audio", key: key, timestamp: 1_000)

      <<head::binary-size(4), _timestamp::32, tail::binary>> = packet
      altered = <<head::binary, 1_001::32, tail::binary>>

      assert {:error, :bad_tag} = AudioPacket.open(altered, key)
    end

    test "a packet with no room for a nonce and a tag is refused" do
      key = key()

      for payload <- [<<>>, :binary.copy(<<0>>, 8), :binary.copy(<<0>>, 23)] do
        short =
          <<2::2, 0::1, 0::1, 0::4, 0::1, @payload_type::7, 1::16, 2::32, 3::32, payload::binary>>

        assert {:error, :truncated} = AudioPacket.open(short, key)
      end
    end

    test "something that is not RTP at all is refused" do
      assert {:error, _reason} = AudioPacket.open(<<0, 1, 2, 3>>, key())
      assert {:error, _reason} = AudioPacket.open(:crypto.strong_rand_bytes(64), key())
    end

    test "an empty datagram is refused" do
      assert {:error, _reason} = AudioPacket.open(<<>>, key())
    end
  end
end
