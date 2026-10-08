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
  alias PiFi.AirPlay.NowPlaying
  alias PiFi.AirPlay.PairSetup
  alias PiFi.AirPlay.PairVerify
  alias PiFi.AirPlay.Parameters
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

  **Every request is logged with the status it was answered with**, at `debug`, which a
  development firmware writes and a production one does not. A session that ends early
  leaves nothing behind but this: a telephone that gives up does it quietly, and the
  last request it was happy with is the whole of the evidence. The body is never
  logged — it carries the keys of a pairing.
  """
  @spec route(Request.t(), Session.t()) :: {binary(), Session.t()}
  def route(%Request{} = request, session) do
    {reply, session} = answer(request, session)

    Logger.debug(
      "AirPlay #{request.method} #{request.uri} from #{session.sender}: #{status(reply)}"
    )

    {reply, session}
  end

  defp answer(%Request{method: "OPTIONS"} = request, session) do
    {Rtsp.reply_to(request, 200, %{"public" => @implemented}), session}
  end

  defp answer(%Request{method: "GET", uri: "/info"} = request, session) do
    body = Info.body(session.device, session.sender)

    {Rtsp.reply_to(request, 200, %{"content-type" => @binary}, body), session}
  end

  defp answer(%Request{method: "POST", uri: "/fp-setup"} = request, session) do
    case FairPlay.setup(request.body) do
      {:ok, reply} -> {Rtsp.reply_to(request, 200, %{"content-type" => @binary}, reply), session}
      {:error, _reason} -> {Rtsp.reply_to(request, 400), session}
    end
  end

  defp answer(%Request{method: "POST", uri: "/pair-setup"} = request, session) do
    pair_setup(request, session, step(request.body))
  end

  defp answer(%Request{method: "POST", uri: "/pair-verify"} = request, session) do
    pair_verify(request, session, step(request.body))
  end

  # **This is where a sender stops asking and starts sending.** It arrives twice: the
  # first describes the session and asks where to send events, the second describes the
  # audio and asks where to send it. `PiFi.AirPlay.Session` opens the ports and says what
  # to answer with.
  defp answer(%Request{method: "SETUP"} = request, session) do
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
  defp answer(%Request{method: "RECORD"} = request, session) do
    {Rtsp.reply_to(request, 200, %{"audio-latency" => "0"}), session}
  end

  # A sender that is finished says so. One that crashed says nothing, and the connection
  # ending is what closes the ports in that case.
  defp answer(%Request{method: "TEARDOWN"} = request, session) do
    Logger.info("The AirPlay sender at #{session.sender} said it was finished.")

    stopped(session.audio)

    {Rtsp.reply_to(request, 200), %{session | audio: Audio.close(session.audio)}}
  end

  # **`SETRATEANCHORTIME` is how a buffered sender says play and pause**, and a 501 to
  # it is a sender that never starts. A telephone sent this about forty times to a
  # board at 192.168.3.142 on 2026-10-08, got a refusal each time, and then tore the
  # session down without a note of sound.
  #
  # `rate` is the whole of what this receiver reads. The `anchorTime` and the RTP
  # timestamp beside it say *when* to start, against a PTP clock shared with the other
  # speakers of a group — and one speaker has nothing to agree with, so it plays what
  # arrives when it arrives. See `PiFi.AirPlay.BufferedSocket`.
  defp answer(%Request{method: "SETRATEANCHORTIME"} = request, session) do
    anchored(session, rate(request.body))

    {Rtsp.reply_to(request, 200), session}
  end

  # A buffered sender asks for these as a matter of course, and each one is a thing
  # this receiver has nothing to do about: `SETPEERS` is the list of the other speakers
  # of a group, `/audioMode` says whether the audio is music or a game, `/command`
  # carries the controls of a sender that drives its own playback, and `/feedback` is a
  # poll. **A 501 to any of them stops some senders**, so each answers 200 and does
  # nothing, in the way `FLUSH` has always done.
  #
  # `FLUSH` is a sender skipping, and there is nothing held here to throw away: the
  # jitter buffer holds a fraction of a second and the packets after it carry their own
  # sequence numbers. Answering 200 is honest, and answering 501 would stop a sender.
  defp answer(%Request{method: method} = request, session)
       when method in ["FLUSH", "GET_PARAMETER", "SETPEERS"] do
    {Rtsp.reply_to(request, 200), session}
  end

  # **This is where the metadata is, and this firmware does not read it yet.** Bit 50 of
  # `PiFi.AirPlay.Advertisement` asks a sender to send what is playing as a binary plist
  # to this route, and nothing then comes through the AirPlay 1 path — so the title, the
  # artist and the artwork of the track are all in this body.
  #
  # **The shape of it is written down nowhere this project trusts.** Shairport Sync does
  # not set bit 50, so it has no plist path to read, and the answer from one receiver
  # project was plainly invented. `PiFi.AirPlay.NowPlaying` therefore reads the message
  # a real telephone sent, and the debug line stays so that the next telephone to send
  # something else can be read the same way.
  defp answer(%Request{method: "POST", uri: "/command"} = request, session) do
    Logger.debug("AirPlay /command from #{session.sender}: #{described(request.body)}")

    playing(request.body)

    {Rtsp.reply_to(request, 200), session}
  end

  # A sender that sends nothing to `/command` may still send something here, and this
  # says which. `text/parameters` carries the volume and the progress of the AirPlay 1
  # path, which bit 50 is supposed to replace.
  defp answer(%Request{method: "SET_PARAMETER"} = request, session) do
    Logger.debug(
      "AirPlay SET_PARAMETER from #{session.sender} as #{content_type(request)}: " <>
        described(request.body)
    )

    asked(Parameters.read(request.body))

    {Rtsp.reply_to(request, 200), session}
  end

  defp answer(%Request{method: "POST", uri: uri} = request, session)
       when uri in ["/audioMode", "/feedback"] do
    {Rtsp.reply_to(request, 200), session}
  end

  # **A sender asks for these again and again**, so the `debug` line of `route/2` is the
  # whole of what this says. `POST /feedback` arrives every couple of seconds, and a
  # line at `info` for each one would fill the log of a device the way the 404s of a
  # Plex controller once did. See the note on the level in `config/target.exs`.
  defp answer(%Request{} = request, session) do
    {Rtsp.reply_to(request, 501), session}
  end

  # **A rate of nothing is a pause and a rate of one is a play.** A sender sends the
  # number as a real or as an integer depending on what it is doing, so this reads
  # both, and a body it cannot read at all leaves the player as it was: a stream that
  # stopped for a reason nobody can name is worse than one that keeps playing.
  defp rate(body) do
    case BinaryPlist.decode(body) do
      {:ok, %{"rate" => rate}} when is_number(rate) -> rate
      _other -> nil
    end
  end

  defp anchored(_session, nil), do: :ok

  defp anchored(%Session{audio: %Audio{audio: nil}}, _rate), do: :ok

  defp anchored(_session, rate) when rate > 0, do: Monitor.resumed()
  defp anchored(_session, _rate), do: Monitor.paused()

  defp asked({:ok, {:volume, percent}}), do: Monitor.volume(percent)
  defp asked(:ignore), do: :ok

  # **Whatever this says, the answer is 200.** A body that will not decode, a message of
  # a kind this firmware does not read, and a picture that the cache refuses are all
  # things a person should not hear about by the music stopping.
  defp playing(body) do
    with {:ok, plist} <- BinaryPlist.decode(body),
         {:ok, playing} <- NowPlaying.read(plist) do
      Monitor.now_playing(playing)
    else
      _other -> :ok
    end
  end

  defp content_type(request) do
    case Rtsp.header(request, "content-type") do
      {:ok, type} -> type
      :error -> "nothing"
    end
  end

  # A body is a plist, or it is the text of the AirPlay 1 path, or it is a picture.
  defp described(<<>>), do: "an empty body"

  defp described(body) do
    case BinaryPlist.decode(body) do
      {:ok, plist} ->
        inspect(shortened(plist), limit: :infinity)

      {:error, reason} ->
        "#{byte_size(body)} bytes, no plist (#{inspect(reason)}): #{shortened(body)}"
    end
  end

  # **A picture in a log line fills the whole log.** A development firmware keeps 4096
  # lines and a JPEG of a record sleeve is tens of thousands of bytes, so a binary that
  # is not words becomes its own size. See the note on the level in `config/target.exs`.
  defp shortened(%{} = plist) when not is_struct(plist) do
    Map.new(plist, fn {key, value} -> {key, shortened(value)} end)
  end

  defp shortened(values) when is_list(values), do: Enum.map(values, &shortened/1)

  defp shortened(binary) when is_binary(binary) do
    if String.printable?(binary) and byte_size(binary) <= 256 do
      binary
    else
      "<#{byte_size(binary)} bytes>"
    end
  end

  defp shortened(value), do: value

  defp status(reply) do
    with [line | _rest] <- :binary.split(reply, "\r\n"),
         [_version, status] <- :binary.split(line, " ") do
      status
    else
      _unexpected -> reply
    end
  end

  # The player is told once the audio socket exists, which is the second `SETUP`.
  defp streaming(%Audio{audio: nil}), do: :ok
  defp streaming(%Audio{audio: socket, kind: kind}), do: Monitor.started(socket, kind)

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
