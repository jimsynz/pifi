defmodule PiFi.AirPlay.FairPlay do
  @moduledoc """
  Answers `/fp-setup`, which every sender does before it will send audio.

  A telephone posts two messages here and expects two answers. It will not go on to
  `SETUP` until it gets them, so a receiver that ignores this route is one that pairs
  and then never plays.

  ## This is not the FairPlay cipher, and it does not need to be

  FairPlay proper is Apple's DRM, and the reverse-engineered version of it runs to about
  six thousand lines of substitution tables. **None of it is reachable from the audio
  path of AirPlay 2.** The key that protects the audio comes out of Pair-Verify — see
  `PiFi.AirPlay.PairVerify` — and `/fp-setup` is a separate handshake whose output this
  receiver never uses for anything. So the answers are constants.

  That matters for more than effort. The full cipher is published under the GPL, and
  this firmware is Apache-2.0, so porting it was never available. The constants below
  come from Shairport Sync's `rtsp.c`, which is MIT, and they are the same bytes in
  every implementation because they are what Apple's sender expects to see.

  ## The two messages

  Both carry a twelve byte header: `FPLY`, a version, a type, a sequence number, a zero,
  and then the length of what follows as four big-endian bytes.

  - **Sequence 1** names a *mode* in byte 14. Answer with the constant for that mode,
    sequence 2, 130 bytes.
  - **Sequence 3** ends with twenty bytes that the sender wants back. Answer with those
    same twenty bytes, sequence 4.

  **Sequence 3 is an echo and not a computation.** A reader who assumed otherwise would
  go looking for the cipher again.

  ## It refuses rather than guessing

  This answers a request from the network, so the body can be anything. A version that
  is not 3, a mode outside the four, a message too short to hold what it claims: each is
  an error, because a made-up answer here is a telephone that hangs part way through
  starting a stream.
  """

  @magic "FPLY"
  @version 3
  @message_type 1
  @setup1_sequence 1
  @setup2_sequence 3
  @echoed_bytes 20

  @reply_bytes 130

  # Body 0 is the message type, body 1 is the mode, and the rest is opaque to us.
  @reply_hex %{
    0 =>
      "02000F9F3F9E0A2521DBDF312AB2BFB29E8D232B6376A8C818701D22AE93D82737FEAF9DB4FDF41C" <>
        "2DBA9D1F49CAAABF6591AC1F7BC6F7E0663D21AFE01565953EAB81F418CEED095ADB7C3D0E254909" <>
        "A79831D49C3982973434FACB42C63A1CD911A6FE941A8A6D4A743B46C3A7649E44C78955E49D8155" <>
        "009549C4E2F7A3F6D5BA",
    1 =>
      "0201CF32A25714B2524F8AA0AD7AF164E37BCF4424E200047EFC0AD67AFCD95DED1C2730BB591B96" <>
        "2ED63A9C4DED88BA8FC78DE64D91CCFD5C7B56DA88E31F5CCEAFC7431995A01665A54E1939D25B94" <>
        "DB64B9E45D8D063E1E6AF07E9656162B0EFA404275EA5A44D9591C7256B9FBE6513898B802277219" <>
        "88571650942AD946688A",
    2 =>
      "0202C169A352EEED35B18CDD9C58D64F16C1519A89EB5317BD0D4336CD68F638FF9D016A5B52B7FA" <>
        "9216B2B65482C78444118121A2C7FED83DB7119E9182AAD7D18C7063E2A457555910AF9E0EFC7634" <>
        "7D164043807F581EE4FBE42CA9DEDC1B5EB2A3AA3D2ECD59E7EEE70B3629F22AFD161D877353DDB9" <>
        "9ADC8E07006E56F850CE",
    3 =>
      "02039001E1727E0F57F9F5880DB104A6257A23F5CFFF1ABBE1E93045251AFB97EB9FC0011EBE0F3A" <>
        "81DF5B691D76ACB2F7A5C708E3D328F56BB39DBDE5F29C8A17F481487E3AE863C678325422E6F78E" <>
        "166D18AA7FD636258BCE28726F661F738893CE44311E4BE6C0535193E5EF72E8686233729C227D82" <>
        "0C999445D89246C8C359"
  }

  # A constant of the wrong length is a handshake that fails somewhere else entirely, so
  # the length is checked as this compiles rather than on a board.
  @replies Map.new(@reply_hex, fn {mode, hex} ->
             decoded = Base.decode16!(hex)

             byte_size(decoded) == @reply_bytes ||
               raise "FairPlay reply for mode #{mode} is #{byte_size(decoded)} bytes"

             {mode, decoded}
           end)

  @modes Map.keys(@replies)

  @doc """
  Answer one `/fp-setup` message.

  The first message names a mode and gets the constant for it.

      iex> request = <<"FPLY", 3, 1, 1, 0, 130::32>> <> <<2, 0>> <> :binary.copy(<<0>>, 128)
      iex> {:ok, reply} = PiFi.AirPlay.FairPlay.setup(request)
      iex> byte_size(reply)
      142

  The second hands back the twenty bytes it ended with.

      iex> tail = :binary.copy("z", 20)
      iex> request = <<"FPLY", 3, 1, 3, 0, 164::32>> <> :binary.copy(<<7>>, 144) <> tail
      iex> {:ok, reply} = PiFi.AirPlay.FairPlay.setup(request)
      iex> reply
      <<"FPLY", 3, 1, 4, 0, 20::32>> <> tail

  A sender speaking a version this does not know is refused rather than answered.

      iex> PiFi.AirPlay.FairPlay.setup(<<"FPLY", 9, 1, 1, 0, 0::32, 0, 0, 0>>)
      {:error, {:bad_version, 9}}
  """
  @spec setup(binary()) :: {:ok, binary()} | {:error, term()}
  def setup(<<@magic, version, _rest::binary>>) when version != @version do
    {:error, {:bad_version, version}}
  end

  def setup(<<@magic, @version, type, _rest::binary>>) when type != @message_type do
    {:error, {:bad_type, type}}
  end

  def setup(
        <<@magic, @version, @message_type, @setup1_sequence, _zero, _length::32, _type, mode,
          _rest::binary>>
      )
      when mode in @modes do
    {:ok, header(@setup1_sequence + 1, @reply_bytes) <> Map.fetch!(@replies, mode)}
  end

  def setup(
        <<@magic, @version, @message_type, @setup1_sequence, _zero, _length::32, _type, mode,
          _rest::binary>>
      ) do
    {:error, {:bad_mode, mode}}
  end

  def setup(
        <<@magic, @version, @message_type, @setup2_sequence, _zero, _length::32, body::binary>>
      )
      when byte_size(body) >= @echoed_bytes do
    skipped = byte_size(body) - @echoed_bytes
    <<_ignored::binary-size(^skipped), echoed::binary-size(@echoed_bytes)>> = body

    {:ok, header(@setup2_sequence + 1, @echoed_bytes) <> echoed}
  end

  # **The guard matters.** Without it a message of a sequence this does answer, but too
  # short to hold what that sequence needs, is reported as a sequence it cannot
  # answer — an error that sends a reader looking in the wrong place.
  def setup(<<@magic, @version, @message_type, sequence, _rest::binary>>)
      when sequence not in [@setup1_sequence, @setup2_sequence] do
    {:error, {:bad_sequence, sequence}}
  end

  def setup(_short), do: {:error, :truncated}

  @doc """
  The twelve byte header both answers start with.

  **The length counts what follows the header**, and it is the one field a sender reads
  to know where the message ends.

      iex> PiFi.AirPlay.FairPlay.header(4, 20)
      <<"FPLY", 3, 1, 4, 0, 20::32>>
  """
  @spec header(non_neg_integer(), non_neg_integer()) :: binary()
  def header(sequence, length) do
    <<@magic, @version, @message_type, sequence, 0, length::32>>
  end
end
