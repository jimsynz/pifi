defmodule PiFi.AirPlay.Rtp do
  @moduledoc """
  Reads the packets that carry the audio, from RFC 3550.

  AirPlay sends audio as RTP over UDP, and everything about the header is the standard
  one. What is specific to AirPlay is which payload types mean what, and that belongs to
  whatever reads these rather than here.

  ## The header is twelve bytes and then some

  Twelve fixed bytes, then four more for each contributing source, then an optional
  extension that names its own length. **A reader that assumed twelve would hand the
  decoder the first few bytes of its own payload** for any packet that carried either,
  which is a stream that plays noise rather than one that fails.

  ## The sequence number wraps, and it has to

  It is sixteen bits, so it goes back to zero every 65536 packets — about twenty-four
  minutes at the rate AirPlay sends. **Anything ordering these has to treat 0 as
  following 65535**, and `later?/2` is that comparison: it answers by the shorter way
  round the circle rather than by which number is larger.

  ## It refuses rather than guessing

  These arrive on a UDP socket, so a packet can be anything at all. A version that is
  not 2, a header longer than the packet, an extension that claims more than is there:
  each is an error, and none is a packet handed on with a plausible-looking payload.
  """

  @version 2
  @half 0x8000

  defmodule Packet do
    @moduledoc "One RTP packet."

    @type t :: %__MODULE__{
            marker?: boolean(),
            payload_type: 0..127,
            sequence: 0..65_535,
            timestamp: non_neg_integer(),
            ssrc: non_neg_integer(),
            csrcs: [non_neg_integer()],
            extension: {non_neg_integer(), binary()} | nil,
            payload: binary()
          }

    defstruct marker?: false,
              payload_type: 0,
              sequence: 0,
              timestamp: 0,
              ssrc: 0,
              csrcs: [],
              extension: nil,
              payload: <<>>
  end

  @doc """
  Read one packet.

      iex> packet = <<2::2, 0::1, 0::1, 0::4, 0::1, 96::7, 7::16, 1000::32, 42::32, "audio">>
      iex> {:ok, read} = PiFi.AirPlay.Rtp.parse(packet)
      iex> {read.payload_type, read.sequence, read.timestamp, read.ssrc, read.payload}
      {96, 7, 1000, 42, "audio"}

  **A packet that is not RTP version 2 is refused**, because a UDP socket takes whatever
  is sent to it.

      iex> PiFi.AirPlay.Rtp.parse(<<0::2, 0::6, 0::8, 0::16, 0::32, 0::32>>)
      {:error, {:bad_version, 0}}
  """
  @spec parse(binary()) :: {:ok, Packet.t()} | {:error, term()}
  def parse(
        <<@version::2, _padding::1, extension?::1, count::4, marker::1, payload_type::7,
          sequence::16, timestamp::32, ssrc::32, rest::binary>>
      ) do
    with {:ok, csrcs, rest} <- csrcs(rest, count),
         {:ok, extension, payload} <- extension(rest, extension? == 1) do
      {:ok,
       %Packet{
         marker?: marker == 1,
         payload_type: payload_type,
         sequence: sequence,
         timestamp: timestamp,
         ssrc: ssrc,
         csrcs: csrcs,
         extension: extension,
         payload: payload
       }}
    end
  end

  # **The guard matters.** Without it a packet too short to hold a header, but starting
  # with a valid version, is reported as a bad version of 2 — an error message that
  # says the opposite of what is wrong.
  def parse(<<version::2, _rest::bitstring>>) when version != @version do
    {:error, {:bad_version, version}}
  end

  def parse(_short), do: {:error, :truncated}

  @doc """
  Whether one sequence number comes after another, allowing for the wrap.

  **Sixteen bits wrap every 65536 packets**, about twenty-four minutes of audio, so a
  comparison that asked which number was larger would decide the stream had run
  backwards once every twenty-four minutes. This answers by the shorter way round the
  circle.

      iex> PiFi.AirPlay.Rtp.later?(5, 4)
      true

      iex> PiFi.AirPlay.Rtp.later?(4, 5)
      false

      iex> PiFi.AirPlay.Rtp.later?(0, 65535)
      true

      iex> PiFi.AirPlay.Rtp.later?(65535, 0)
      false
  """
  @spec later?(0..65_535, 0..65_535) :: boolean()
  def later?(one, two) do
    difference = Integer.mod(one - two, 0x10000)

    difference != 0 and difference < @half
  end

  @doc """
  How many packets separate two sequence numbers, the short way round.

      iex> PiFi.AirPlay.Rtp.distance(10, 4)
      6

      iex> PiFi.AirPlay.Rtp.distance(2, 65534)
      4
  """
  @spec distance(0..65_535, 0..65_535) :: non_neg_integer()
  def distance(one, two), do: Integer.mod(one - two, 0x10000)

  defp csrcs(rest, 0), do: {:ok, [], rest}

  defp csrcs(rest, count) do
    bytes = count * 4

    case rest do
      <<table::binary-size(^bytes), remainder::binary>> ->
        {:ok, for(<<csrc::32 <- table>>, do: csrc), remainder}

      _short ->
        {:error, :truncated}
    end
  end

  defp extension(rest, false), do: {:ok, nil, rest}

  # **The length counts 32-bit words and not bytes**, which is the trap: a reader that
  # took it as bytes keeps a quarter of the extension and hands the rest to the decoder.
  defp extension(<<profile::16, words::16, rest::binary>>, true) do
    bytes = words * 4

    case rest do
      <<data::binary-size(^bytes), payload::binary>> -> {:ok, {profile, data}, payload}
      _short -> {:error, :truncated}
    end
  end

  defp extension(_short, true), do: {:error, :truncated}
end
