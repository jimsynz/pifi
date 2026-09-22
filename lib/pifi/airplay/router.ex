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

  ## What it answers now

  `GET /info`, `POST /fp-setup`, `POST /pair-setup` and `POST /pair-verify`, which is
  everything between a telephone finding this device and being paired with it.
  `OPTIONS` answers with the list. Anything else is `501`, because a receiver that
  answered `200` to a `SETUP` it cannot do would have the telephone waiting for audio
  that is never coming.
  """

  alias PiFi.AirPlay.FairPlay
  alias PiFi.AirPlay.Info
  alias PiFi.AirPlay.PairSetup
  alias PiFi.AirPlay.PairVerify
  alias PiFi.AirPlay.Rtsp
  alias PiFi.AirPlay.Rtsp.Request
  alias PiFi.AirPlay.Tlv8

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
            keys: term()
          }

    defstruct [:device, :sender, :data_dir, :setup, :verify, :keys]
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

  def route(%Request{} = request, session) do
    {Rtsp.reply_to(request, 501), session}
  end

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

      # A transient pairing is finished here, and the key it leaves is what the
      # connection uses from now on.
      {:done, reply, key} ->
        {tlv(request, reply), %{session | setup: nil, keys: key}}

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
