defmodule PiFi.AirPlay.AudioPacket do
  @moduledoc """
  Takes the encryption off one packet of AirPlay audio.

  Every audio packet of an AirPlay 2 session is sealed with ChaCha20-Poly1305 under the
  key the sender gave in `SETUP`. This undoes that and hands back the frame underneath,
  which is what `PiFi.AirPlay.Alac` decodes.

  ## It really is an ordinary RTP packet

  This is worth saying because the reference implementation makes it look otherwise:
  Shairport Sync skips the first two bytes and works in offsets from there, which reads
  as a private framing. Lining those offsets up against RFC 3550 shows they are the
  standard header —

    * the sealed audio starts at byte twelve, right where an RTP payload starts;
    * the authenticated data is bytes four to eleven, which is the timestamp and the
      synchronisation source;
    * the sequence number and timestamp are where RTP puts them.

  So `PiFi.AirPlay.Rtp` reads the header and this only does the cipher. Nothing here
  parses bytes that module already parses.

  ## The nonce arrives short

  A sender sends eight bytes of nonce at the very end of the payload, and
  ChaCha20-Poly1305 as the IETF specifies it takes twelve. **The eight are the low end
  and the four zero bytes go in front**, which is the one detail that has no clue in the
  packet: a receiver that padded the other way gets a tag failure on every packet and
  nothing to say why.

  ## A packet that fails is a gap and not an error

  These arrive on a UDP socket from anything on the network. A tag that does not verify
  means a packet was damaged or is not ours, and the answer is to drop it —
  `PiFi.AirPlay.JitterBuffer` already reports the gaps and something above conceals
  them. Nothing here raises.
  """

  alias PiFi.AirPlay.Cipher
  alias PiFi.AirPlay.Rtp

  @nonce_bytes 8
  @padding 4
  # One source of truth for this, read at compile time so a guard can use it.
  @tag_bytes Cipher.tag_bytes()

  @typedoc "One packet of audio, with the encryption taken off."
  @type t :: %{sequence: 0..65_535, timestamp: non_neg_integer(), payload: binary()}

  @doc """
  Read one datagram and take the encryption off it.

  `key` is the thirty-two bytes a sender sent as `shk` in its `SETUP`, which
  `PiFi.AirPlay.Setup` has already refused at any other length.
  """
  @spec open(binary(), binary()) :: {:ok, t()} | {:error, term()}
  def open(datagram, key) when is_binary(datagram) and is_binary(key) do
    with {:ok, packet} <- Rtp.parse(datagram),
         {:ok, sealed, nonce} <- split(packet.payload),
         {:ok, payload} <- Cipher.open(key, nonce, sealed, aad(packet)) do
      {:ok, %{sequence: packet.sequence, timestamp: packet.timestamp, payload: payload}}
    end
  end

  # The bytes the sender authenticated but did not encrypt, which is the timestamp and
  # the synchronisation source exactly as they sit in the header.
  defp aad(%{timestamp: timestamp, ssrc: ssrc}), do: <<timestamp::32, ssrc::32>>

  # The shortest real payload is a sixteen-byte tag and an eight-byte nonce with nothing
  # between them, which is a frame of no audio. It authenticates like any other, so it is
  # taken rather than dropped; anything shorter cannot hold both.
  defp split(payload) when byte_size(payload) < @nonce_bytes + @tag_bytes,
    do: {:error, :truncated}

  defp split(payload) do
    sealed = binary_part(payload, 0, byte_size(payload) - @nonce_bytes)
    short = binary_part(payload, byte_size(payload) - @nonce_bytes, @nonce_bytes)

    {:ok, sealed, <<0::size(@padding * 8), short::binary>>}
  end
end
