defmodule PiFi.AirPlay.Router do
  @moduledoc """
  Decides which part of this receiver answers a request, and keeps what carries over.

  A connection is a sequence of requests that share state: the pairing half-finished in
  one message is needed by the next. This holds that state and nothing else — it opens
  no socket and reads no clock, so the whole of the conversation can be tested by
  handing it requests.

  ## Pairing is one route with a state inside it

  `/pair-setup` and `/pair-verify` each carry their own step in a TLV field rather than
  in the path, so the route is chosen by the URI and the step by what arrived. **A
  telephone that sends M3 without having sent M1 gets a refusal**, not a crash: the
  state it refers to is not there, and a receiver that matched on the message alone
  would carry on with `nil` where a salt should be.

  ## What it answers

  `GET /info`, `POST /fp-setup` and the two pairing routes carry a telephone from finding
  this device to being paired with it. `SETUP`, `RECORD` and `TEARDOWN` carry it from
  there to sending audio.

  **`SETUP` answered `501` until there was audio at the other end of it**, on the
  argument that a receiver claiming to be ready would leave a telephone showing it as
  playing while nothing came out. There is now: the ports open, the packets are decrypted
  and decoded, and `PiFi.AirPlay.Monitor` hands the stream to the player. What is not
  there yet is PTP, which is how several speakers agree with each other and which one
  speaker has nothing to agree with.

  `FLUSH`, `SET_PARAMETER` and `GET_PARAMETER` answer `200` and do nothing. A sender that
  skips has nothing held here to throw away — the jitter buffer holds a fraction of a
  second and every packet after it carries its own sequence number — and answering `501`
  to a method a sender expects to succeed stops the session over nothing.
  """

  alias PiFi.AirPlay.BinaryPlist
  alias PiFi.AirPlay.FairPlay
  alias PiFi.AirPlay.Info
  alias PiFi.AirPlay.Monitor
  alias PiFi.AirPlay.PairSetup
  alias PiFi.AirPlay.PairVerify
  alias PiFi.AirPlay.Rtsp
  alias PiFi.AirPlay.Rtsp.Request
  alias PiFi.AirPlay.SecureChannel
  alias PiFi.AirPlay.Session, as: Audio
  alias PiFi.AirPlay.Tlv8

  require Logger

  @state 0x06

  @binary "application/octet-stream"
  @implemented "ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER, POST, GET"

  defmodule Session do
    @moduledoc "What one connection remembers between requests."

    @type t :: %__MODULE__{
            device: map(),
            sender: String.t(),
            data_dir: Path.t(),
            setup: term(),
            verify: term(),
            keys: term(),
            audio: Audio.t()
          }

    defstruct [:device, :sender, :data_dir, :setup, :verify, :keys, audio: %Audio{}]
  end

  @doc """
  A session for one connection.

  `sender` is the address it came from, which `GET /info` hands back.
  """
  @spec new(map(), String.t(), Path.t()) :: Session.t()
  def new(device, sender, data_dir \\ "/root") do
    %Session{device: device, sender: sender, data_dir: data_dir}
  end

  @doc """
  Answer one request, and say what the connection remembers afterwards.
  """
  @spec route(Request.t(), Session.t()) :: {binary(), Session.t()}
  def route(%Request{method: "OPTIONS"} = request, session) do
    {Rtsp.reply_to(request, 200, %{"public" => @implemented}), session}
  end

  def route(%Request{method: "GET", uri: "/info"} = request, session) do
    body = Info.body(session.device, session.sender)

    {Rtsp.reply_to(request, 200, %{"content-type" => @binary}, body), session}
  end

  def route(%Request{method: "POST", uri: "/fp-setup"} = request, session) do
    case FairPlay.setup(request.body) do
      {:ok, reply} -> {Rtsp.reply_to(request, 200, %{"content-type" => @binary}, reply), session}
      {:error, _reason} -> {Rtsp.reply_to(request, 400), session}
    end
  end

  def route(%Request{method: "POST", uri: "/pair-setup"} = request, session) do
    pair_setup(request, session, step(request.body))
  end

  def route(%Request{method: "POST", uri: "/pair-verify"} = request, session) do
    pair_verify(request, session, step(request.body))
  end

  # **This is where a sender stops asking and starts sending.** It arrives twice: the
  # first describes the session and asks where to send events, the second describes the
  # audio and asks where to send it. `PiFi.AirPlay.Session` opens the ports and says what
  # to answer with.
  def route(%Request{method: "SETUP"} = request, session) do
    case Audio.setup(session.audio, request.body) do
      {:ok, reply, audio} ->
        streaming(audio)

        {Rtsp.reply_to(request, 200, %{"content-type" => @binary}, BinaryPlist.encode(reply)),
         %{session | audio: audio}}

      {:error, reason} ->
        Logger.warning("An AirPlay SETUP was refused: #{inspect(reason)}.")

        {Rtsp.reply_to(request, 400), session}
    end
  end

  # **Nothing to do, and that is the whole of it for AirPlay 2.** The latency of the
  # classic protocol was this receiver telling a sender how far ahead to run; a version 2
  # sender works that out from the timing channel, so every receiver answers zero.
  def route(%Request{method: "RECORD"} = request, session) do
    {Rtsp.reply_to(request, 200, %{"audio-latency" => "0"}), session}
  end

  # A sender that is finished says so. One that crashed says nothing, and the connection
  # ending is what closes the ports in that case.
  def route(%Request{method: "TEARDOWN"} = request, session) do
    stopped(session.audio)

    {Rtsp.reply_to(request, 200), %{session | audio: Audio.close(session.audio)}}
  end

  # `FLUSH` is a sender skipping, and there is nothing held here to throw away: the
  # jitter buffer holds a fraction of a second and the packets after it carry their own
  # sequence numbers. Answering 200 is honest, and answering 501 would stop a sender.
  def route(%Request{method: method} = request, session)
      when method in ["FLUSH", "SET_PARAMETER", "GET_PARAMETER"] do
    {Rtsp.reply_to(request, 200), session}
  end

  def route(%Request{} = request, session) do
    {Rtsp.reply_to(request, 501), session}
  end

  # The player is told once the audio socket exists, which is the second `SETUP`.
  defp streaming(%Audio{audio: nil}), do: :ok
  defp streaming(%Audio{audio: socket}), do: Monitor.started(socket)

  defp stopped(%Audio{audio: nil}), do: :ok
  defp stopped(%Audio{audio: socket}), do: Monitor.stopped(socket)

  defp pair_setup(request, session, 1) do
    case PairSetup.start(identifier(session), request.body) do
      {:ok, reply, exchange} ->
        {tlv(request, reply), %{session | setup: exchange}}

      {:error, _reason} ->
        {tlv(request, PairSetup.refusal(2)), session}
    end
  end

  defp pair_setup(request, %Session{setup: nil} = session, 3) do
    {tlv(request, PairSetup.refusal(4)), session}
  end

  defp pair_setup(request, session, 3) do
    case PairSetup.prove(session.setup, request.body) do
      {:ok, reply, exchange} ->
        {tlv(request, reply), %{session | setup: exchange}}

      # A transient pairing is finished here, and the secret it leaves gives the keys
      # the connection uses from now on — the same two a Pair-Verify would have left.
      {:done, reply, secret} ->
        {tlv(request, reply), %{session | setup: nil, keys: SecureChannel.keys(secret)}}

      {:error, _reason} ->
        {tlv(request, PairSetup.refusal(4)), session}
    end
  end

  defp pair_setup(request, %Session{setup: nil} = session, 5) do
    {tlv(request, PairSetup.refusal(6)), session}
  end

  defp pair_setup(request, session, 5) do
    case PairSetup.finish(session.setup, request.body, remember(session), session.data_dir) do
      {:ok, reply} -> {tlv(request, reply), %{session | setup: nil}}
      {:error, _reason} -> {tlv(request, PairSetup.refusal(6)), session}
    end
  end

  defp pair_setup(request, session, _step) do
    {tlv(request, PairSetup.refusal(2)), session}
  end

  defp pair_verify(request, session, 1) do
    case PairVerify.start(identifier(session), request.body, session.data_dir) do
      {:ok, reply, exchange} -> {tlv(request, reply), %{session | verify: exchange}}
      {:error, _reason} -> {tlv(request, PairVerify.refusal()), session}
    end
  end

  defp pair_verify(request, %Session{verify: nil} = session, 3) do
    {tlv(request, PairVerify.refusal()), session}
  end

  defp pair_verify(request, session, 3) do
    case PairVerify.finish(session.verify, request.body, PiFi.AirPlay.known_key()) do
      {:ok, reply, keys} -> {tlv(request, reply), %{session | verify: nil, keys: keys}}
      {:error, refusal, _reason} -> {tlv(request, refusal), %{session | verify: nil}}
    end
  end

  defp pair_verify(request, session, _step) do
    {tlv(request, PairVerify.refusal()), session}
  end

  defp tlv(request, body) do
    Rtsp.reply_to(request, 200, %{"content-type" => @binary}, body)
  end

  # **The step is in the message and not in the path**, so a body that is not a TLV at
  # all has no step. Zero matches no clause above and gets a refusal.
  defp step(body) do
    with {:ok, items} <- Tlv8.decode(body),
         {:ok, <<step>>} <- Tlv8.fetch(items, @state) do
      step
    else
      _other -> 0
    end
  end

  defp identifier(%Session{device: device}), do: device.device_id

  # Writing the pairing down is a question about what a person set up, so it goes
  # through the domain rather than being decided here.
  defp remember(%Session{}) do
    fn identifier, public_key ->
      case PiFi.AirPlay.pair(identifier, public_key) do
        {:ok, _pairing} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
