defmodule PiFi.AirPlay.RouterTest do
  use ExUnit.Case, async: true

  alias PiFi.AirPlay.BinaryPlist
  alias PiFi.AirPlay.Device
  alias PiFi.AirPlay.Identity
  alias PiFi.AirPlay.PairSetup
  alias PiFi.AirPlay.Router
  alias PiFi.AirPlay.Rtsp
  alias PiFi.AirPlay.Srp
  alias PiFi.AirPlay.Tlv8

  @method 0x00
  @salt 0x02
  @public_key 0x03
  @proof 0x04
  @state 0x06
  @error 0x07
  @flags 0x13

  @hash :sha512

  setup do
    dir = Path.join(System.tmp_dir!(), "airplay-router-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    key = Identity.public_key(dir)

    device = %{
      device_id: Device.device_id(key),
      model: "PiFi1,1",
      name: "Kitchen",
      pi: Device.uuid(key, "pi"),
      psi: Device.uuid(key, "psi"),
      public_key: key,
      version: "1.4.0"
    }

    %{session: Router.new(device, "192.168.1.5:50000", dir), device: device, dir: dir}
  end

  defp request(method, uri, body \\ <<>>, cseq \\ 1) do
    head =
      "#{method} #{uri} RTSP/1.0\r\ncseq: #{cseq}\r\ncontent-length: #{byte_size(body)}\r\n\r\n"

    {:ok, parsed, ""} = Rtsp.parse(head <> body)

    parsed
  end

  defp status(reply) do
    [line | _rest] = String.split(reply, "\r\n")
    [_version, status | _reason] = String.split(line, " ")

    String.to_integer(status)
  end

  defp body(reply) do
    [_head, body] = String.split(reply, "\r\n\r\n", parts: 2)

    body
  end

  describe "answering what it knows" do
    test "OPTIONS lists the methods", %{session: session} do
      {reply, _session} = Router.route(request("OPTIONS", "*"), session)

      assert status(reply) == 200
      assert reply =~ "public:"
      assert reply =~ "SETUP"
    end

    test "GET /info describes the device", %{session: session, device: device} do
      {reply, _session} = Router.route(request("GET", "/info"), session)

      assert status(reply) == 200
      assert {:ok, plist} = BinaryPlist.decode(body(reply))
      assert plist["name"] == "Kitchen"
      assert plist["pk"] == device.public_key
      assert plist["senderAddress"] == "192.168.1.5:50000"
    end

    test "POST /fp-setup answers the first message", %{session: session} do
      message = <<"FPLY", 3, 1, 1, 0, 130::32, 2, 0>> <> :binary.copy(<<0>>, 128)
      {reply, _session} = Router.route(request("POST", "/fp-setup", message), session)

      assert status(reply) == 200
      assert byte_size(body(reply)) == 142
    end

    test "carries the request's CSeq back", %{session: session} do
      {reply, _session} = Router.route(request("GET", "/info", <<>>, 42), session)

      assert reply =~ "cseq: 42"
    end
  end

  describe "answering what it does not know" do
    # A receiver that answered 200 to a SETUP it cannot do leaves the telephone waiting
    # for audio that is never coming.
    test "a method it has not built yet is 501", %{session: session} do
      {reply, _session} = Router.route(request("SETUP", "rtsp://host/stream"), session)

      assert status(reply) == 501
    end

    test "a path it does not serve is 501", %{session: session} do
      {reply, _session} = Router.route(request("GET", "/nonsense"), session)

      assert status(reply) == 501
    end

    test "an fp-setup it cannot read is 400 and not a crash", %{session: session} do
      {reply, _session} = Router.route(request("POST", "/fp-setup", "rubbish"), session)

      assert status(reply) == 400
    end
  end

  describe "pairing, transiently" do
    test "runs M1 to M4 and leaves a key on the session", %{session: session} do
      m1 = Tlv8.encode([{@method, <<0>>}, {@state, <<1>>}, {@flags, <<0x10>>}])
      {reply, session} = Router.route(request("POST", "/pair-setup", m1), session)

      assert status(reply) == 200
      assert {:ok, items} = Tlv8.decode(body(reply))
      assert {:ok, <<2>>} = Tlv8.fetch(items, @state)
      assert session.setup

      {m3, phone} = m3(body(reply))
      {reply, session} = Router.route(request("POST", "/pair-setup", m3), session)

      assert status(reply) == 200
      assert {:ok, items} = Tlv8.decode(body(reply))
      assert {:ok, <<4>>} = Tlv8.fetch(items, @state)

      # Transient pairing is finished at M4, so there is nothing left in progress and
      # the connection has its key.
      assert session.setup == nil
      assert session.keys == phone.session_key
    end

    test "refuses a telephone that did not know the code", %{session: session} do
      m1 = Tlv8.encode([{@method, <<0>>}, {@state, <<1>>}, {@flags, <<0x10>>}])
      {reply, session} = Router.route(request("POST", "/pair-setup", m1), session)

      {m3, _phone} = m3(body(reply), "0000")
      {reply, session} = Router.route(request("POST", "/pair-setup", m3), session)

      assert {:ok, items} = Tlv8.decode(body(reply))
      assert {:ok, <<2>>} = Tlv8.fetch(items, @error)
      assert session.keys == nil
    end
  end

  describe "a step that does not follow" do
    # A receiver that matched on the message alone would carry on with nil where a salt
    # should be.
    test "M3 with no M1 before it is refused", %{session: session} do
      m3 = Tlv8.encode([{@state, <<3>>}, {@public_key, <<1>>}, {@proof, <<2>>}])
      {reply, session} = Router.route(request("POST", "/pair-setup", m3), session)

      assert status(reply) == 200
      assert {:ok, items} = Tlv8.decode(body(reply))
      assert {:ok, <<4>>} = Tlv8.fetch(items, @state)
      assert {:ok, <<2>>} = Tlv8.fetch(items, @error)
      assert session.setup == nil
    end

    test "M5 with no exchange in progress is refused", %{session: session} do
      m5 = Tlv8.encode([{@state, <<5>>}])
      {reply, _session} = Router.route(request("POST", "/pair-setup", m5), session)

      assert {:ok, items} = Tlv8.decode(body(reply))
      assert {:ok, <<6>>} = Tlv8.fetch(items, @state)
      assert {:ok, <<2>>} = Tlv8.fetch(items, @error)
    end

    test "pair-verify M3 with no M1 before it is refused", %{session: session} do
      m3 = Tlv8.encode([{@state, <<3>>}])
      {reply, _session} = Router.route(request("POST", "/pair-verify", m3), session)

      assert {:ok, items} = Tlv8.decode(body(reply))
      assert {:ok, <<2>>} = Tlv8.fetch(items, @error)
    end

    test "a body that is not a TLV at all is refused rather than crashing", %{session: session} do
      {reply, _session} = Router.route(request("POST", "/pair-setup", "rubbish"), session)

      assert status(reply) == 200
      assert {:ok, items} = Tlv8.decode(body(reply))
      assert {:ok, <<2>>} = Tlv8.fetch(items, @error)
    end
  end

  # The telephone's half, enough of it to get to M4.
  defp m3(reply, code \\ nil) do
    code = code || PairSetup.transient_code()
    group = Srp.group_3072()
    {:ok, items} = Tlv8.decode(reply)
    {:ok, server_public} = Tlv8.fetch(items, @public_key)
    {:ok, salt} = Tlv8.fetch(items, @salt)

    server = Srp.value(server_public)
    private = Srp.private_key()

    client =
      :crypto.mod_pow(
        <<group.generator>>,
        :binary.encode_unsigned(private),
        :binary.encode_unsigned(group.prime)
      )
      |> :binary.decode_unsigned()

    x =
      :crypto.hash(@hash, salt <> :crypto.hash(@hash, Srp.username() <> ":" <> code))
      |> :binary.decode_unsigned()
      |> Integer.mod(group.prime - 1)

    k =
      :crypto.hash(
        @hash,
        :binary.encode_unsigned(group.prime) <> Srp.bytes(group, group.generator)
      )
      |> :binary.decode_unsigned()

    u =
      :crypto.hash(@hash, Srp.bytes(group, client) <> Srp.bytes(group, server))
      |> :binary.decode_unsigned()

    gx = pow(group, group.generator, x)
    base = Integer.mod(server - Integer.mod(k * gx, group.prime) + group.prime * k, group.prime)
    session_key = Srp.session_key(@hash, pow(group, base, private + u * x))

    proof = Srp.client_proof(group, @hash, Srp.username(), salt, client, server, session_key)

    {Tlv8.encode([{@state, <<3>>}, {@public_key, Srp.bytes(group, client)}, {@proof, proof}]),
     %{session_key: session_key}}
  end

  defp pow(group, base, exponent) do
    :crypto.mod_pow(
      :binary.encode_unsigned(base),
      :binary.encode_unsigned(exponent),
      :binary.encode_unsigned(group.prime)
    )
    |> :binary.decode_unsigned()
  end
end
