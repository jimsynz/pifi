defmodule PiFi.AirPlay.PairSetupTest do
  use ExUnit.Case, async: true

  doctest PiFi.AirPlay.PairSetup

  alias PiFi.AirPlay.Cipher
  alias PiFi.AirPlay.Hkdf
  alias PiFi.AirPlay.Identity
  alias PiFi.AirPlay.PairSetup
  alias PiFi.AirPlay.Srp
  alias PiFi.AirPlay.Tlv8

  @method 0x00
  @identifier 0x01
  @salt 0x02
  @public_key 0x03
  @proof 0x04
  @encrypted_data 0x05
  @state 0x06
  @error 0x07
  @signature 0x0A
  @flags 0x13

  @hash :sha512
  @key_bytes 32

  setup do
    dir = Path.join(System.tmp_dir!(), "pair-setup-#{System.unique_integer([:positive])}")
    phone_dir = dir <> "-phone"

    on_exit(fn ->
      File.rm_rf(dir)
      File.rm_rf(phone_dir)
    end)

    %{dir: dir, phone: phone_dir, device_id: "PiFi"}
  end

  defp m1(options \\ []) do
    method = Keyword.get(options, :method, <<0x00>>)

    items = [{@method, method}, {@state, <<0x01>>}]

    items =
      if Keyword.get(options, :transient?, false),
        do: items ++ [{@flags, <<0x10>>}],
        else: items

    Tlv8.encode(items)
  end

  # **The telephone's half, written from the specification and not from the code it is
  # testing.** It computes the proof the way a client does, so a change to either side
  # that breaks agreement shows up here.
  defp m3(reply, code) do
    group = Srp.group_3072()
    {:ok, items} = Tlv8.decode(reply)
    {:ok, server_public} = Tlv8.fetch(items, @public_key)
    {:ok, salt} = Tlv8.fetch(items, @salt)

    server = Srp.value(server_public)
    private = Srp.private_key()

    public =
      :crypto.mod_pow(
        <<group.generator>>,
        :binary.encode_unsigned(private),
        :binary.encode_unsigned(group.prime)
      )

    client = :binary.decode_unsigned(public)

    verifier = Srp.verifier(group, @hash, Srp.username(), code, salt)
    session_key = client_session_key(group, code, salt, client, server, private, verifier)

    proof =
      Srp.client_proof(group, @hash, Srp.username(), salt, client, server, session_key)

    {Tlv8.encode([{@state, <<0x03>>}, {@public_key, Srp.bytes(group, client)}, {@proof, proof}]),
     %{session_key: session_key, client: client, server: server, proof: proof, group: group}}
  end

  # S = (B - k·g^x)^(a + u·x) mod N, which is the client's side of the same secret.
  defp client_session_key(group, code, salt, client, server, private, _verifier) do
    x = private_exponent(group, code, salt)
    k = multiplier(group)
    u = scrambler(group, client, server)

    gx = pow(group, group.generator, x)
    base = Integer.mod(server - Integer.mod(k * gx, group.prime) + group.prime * k, group.prime)

    Srp.session_key(@hash, pow(group, base, private + u * x))
  end

  defp private_exponent(group, code, salt) do
    inner = :crypto.hash(@hash, Srp.username() <> ":" <> code)

    :crypto.hash(@hash, salt <> inner)
    |> :binary.decode_unsigned()
    |> Integer.mod(group.prime - 1)
  end

  defp multiplier(group) do
    :crypto.hash(@hash, :binary.encode_unsigned(group.prime) <> Srp.bytes(group, group.generator))
    |> :binary.decode_unsigned()
  end

  defp scrambler(group, client, server) do
    :crypto.hash(@hash, Srp.bytes(group, client) <> Srp.bytes(group, server))
    |> :binary.decode_unsigned()
  end

  defp pow(group, base, exponent) do
    :crypto.mod_pow(
      :binary.encode_unsigned(base),
      :binary.encode_unsigned(exponent),
      :binary.encode_unsigned(group.prime)
    )
    |> :binary.decode_unsigned()
  end

  describe "answering M1" do
    test "sends a salt and a public value", %{device_id: id} do
      assert {:ok, answer, exchange} = PairSetup.start(id, m1())
      assert {:ok, items} = Tlv8.decode(answer)

      assert {:ok, <<0x02>>} = Tlv8.fetch(items, @state)
      assert {:ok, salt} = Tlv8.fetch(items, @salt)
      assert {:ok, public} = Tlv8.fetch(items, @public_key)

      assert byte_size(salt) == 16
      assert byte_size(public) == 384
      assert exchange.salt == salt
    end

    # The padding is the trap. A public value that lost its leading zero hashes
    # differently at each end, which happens about one exchange in two hundred and fifty.
    test "always sends a public value the full width of the prime", %{device_id: id} do
      for _attempt <- 1..30 do
        {:ok, answer, _exchange} = PairSetup.start(id, m1())
        {:ok, items} = Tlv8.decode(answer)
        {:ok, public} = Tlv8.fetch(items, @public_key)

        assert byte_size(public) == 384
      end
    end

    test "a fresh salt each time", %{device_id: id} do
      salts =
        for _attempt <- 1..10 do
          {:ok, _answer, exchange} = PairSetup.start(id, m1())
          exchange.salt
        end

      assert length(Enum.uniq(salts)) == 10
    end

    test "notices the transient flag", %{device_id: id} do
      assert {:ok, _answer, plain} = PairSetup.start(id, m1())
      assert {:ok, _answer, transient} = PairSetup.start(id, m1(transient?: true))

      refute plain.transient?
      assert transient.transient?
    end

    test "refuses a method it does not do", %{device_id: id} do
      assert {:error, {:unsupported_method, <<0x01>>}} =
               PairSetup.start(id, m1(method: <<0x01>>))
    end

    test "refuses a message with no method at all", %{device_id: id} do
      assert {:error, :no_method} = PairSetup.start(id, Tlv8.encode([{@state, <<0x01>>}]))
    end

    test "refuses something that is not a TLV", %{device_id: id} do
      assert {:error, _reason} = PairSetup.start(id, <<0x01, 0xFF, 0x00>>)
    end
  end

  describe "answering M3" do
    test "accepts a telephone that knew the code", %{device_id: id} do
      {:ok, answer, exchange} = PairSetup.start(id, m1())
      {request, phone} = m3(answer, PairSetup.transient_code())

      assert {:ok, reply, proven} = PairSetup.prove(exchange, request)
      assert {:ok, items} = Tlv8.decode(reply)
      assert {:ok, <<0x04>>} = Tlv8.fetch(items, @state)
      assert {:ok, _server_proof} = Tlv8.fetch(items, @proof)

      # Both sides arrived at the same key, which is the whole point of the exchange.
      assert proven.session_key == phone.session_key
    end

    test "sends a proof the telephone can check", %{device_id: id} do
      {:ok, answer, exchange} = PairSetup.start(id, m1())
      {request, phone} = m3(answer, PairSetup.transient_code())

      {:ok, reply, _proven} = PairSetup.prove(exchange, request)
      {:ok, items} = Tlv8.decode(reply)
      {:ok, sent} = Tlv8.fetch(items, @proof)

      expected =
        Srp.server_proof(phone.group, phone.client, phone.proof, phone.session_key, @hash)

      assert sent == expected
    end

    test "refuses a telephone that did not know the code", %{device_id: id} do
      {:ok, answer, exchange} = PairSetup.start(id, m1())
      {request, _phone} = m3(answer, "0000")

      assert {:error, :bad_proof} = PairSetup.prove(exchange, request)
    end

    test "refuses a public value that is zero modulo the prime", %{device_id: id} do
      group = Srp.group_3072()
      {:ok, _answer, exchange} = PairSetup.start(id, m1())

      request =
        Tlv8.encode([
          {@state, <<0x03>>},
          {@public_key, Srp.bytes(group, group.prime)},
          {@proof, :binary.copy(<<0>>, 64)}
        ])

      assert {:error, :bad_client_public} = PairSetup.prove(exchange, request)
    end

    test "refuses a message missing its proof", %{device_id: id} do
      group = Srp.group_3072()
      {:ok, _answer, exchange} = PairSetup.start(id, m1())

      request = Tlv8.encode([{@state, <<0x03>>}, {@public_key, Srp.bytes(group, 2)}])

      assert {:error, {:missing, @proof}} = PairSetup.prove(exchange, request)
    end
  end

  describe "a transient pairing" do
    test "finishes at M4 and hands back the key", %{device_id: id} do
      {:ok, answer, exchange} = PairSetup.start(id, m1(transient?: true))
      {request, phone} = m3(answer, PairSetup.transient_code())

      assert {:done, reply, session_key} = PairSetup.prove(exchange, request)
      assert {:ok, items} = Tlv8.decode(reply)
      assert {:ok, <<0x04>>} = Tlv8.fetch(items, @state)
      assert session_key == phone.session_key
    end

    test "a pairing that is not transient carries on instead", %{device_id: id} do
      {:ok, answer, exchange} = PairSetup.start(id, m1())
      {request, _phone} = m3(answer, PairSetup.transient_code())

      assert {:ok, _reply, %PairSetup.Exchange{}} = PairSetup.prove(exchange, request)
    end
  end

  describe "answering M5" do
    setup %{device_id: id, phone: phone_dir} do
      {:ok, answer, exchange} = PairSetup.start(id, m1())
      {request, phone} = m3(answer, PairSetup.transient_code())
      {:ok, _reply, proven} = PairSetup.prove(exchange, request)

      %{proven: proven, phone_keys: Identity.pair(phone_dir), session_key: phone.session_key}
    end

    defp m5(session_key, identifier, keys, phone_dir) do
      info =
        Hkdf.derive(
          @hash,
          session_key,
          "Pair-Setup-Controller-Sign-Salt",
          "Pair-Setup-Controller-Sign-Info",
          @key_bytes
        )

      signature = Identity.sign(info <> identifier <> keys.public, phone_dir)

      inner =
        Tlv8.encode([
          {@identifier, identifier},
          {@public_key, keys.public},
          {@signature, signature}
        ])

      key =
        Hkdf.derive(
          @hash,
          session_key,
          "Pair-Setup-Encrypt-Salt",
          "Pair-Setup-Encrypt-Info",
          @key_bytes
        )

      sealed = Cipher.seal(key, Cipher.message_nonce("PS-Msg05"), inner)

      Tlv8.encode([{@state, <<0x05>>}, {@encrypted_data, sealed}])
    end

    test "remembers the telephone and answers with its own identity", context do
      %{proven: proven, phone_keys: keys, session_key: session_key} = context
      request = m5(session_key, "telephone", keys, context.phone)
      parent = self()

      remember = fn identifier, public_key ->
        send(parent, {:remembered, identifier, public_key})
        :ok
      end

      assert {:ok, reply} = PairSetup.finish(proven, request, remember, context.dir)
      assert_received {:remembered, "telephone", remembered_key}
      assert remembered_key == keys.public

      assert {:ok, items} = Tlv8.decode(reply)
      assert {:ok, <<0x06>>} = Tlv8.fetch(items, @state)
      assert {:ok, _sealed} = Tlv8.fetch(items, @encrypted_data)
    end

    # The telephone checks this signature, so a receiver that signed the wrong thing
    # pairs successfully here and is rejected at the other end with nothing to say why.
    test "signs what the telephone will check", context do
      %{proven: proven, phone_keys: keys, session_key: session_key} = context
      request = m5(session_key, "telephone", keys, context.phone)

      {:ok, reply} = PairSetup.finish(proven, request, fn _id, _key -> :ok end, context.dir)
      {:ok, items} = Tlv8.decode(reply)
      {:ok, sealed} = Tlv8.fetch(items, @encrypted_data)

      key =
        Hkdf.derive(
          @hash,
          session_key,
          "Pair-Setup-Encrypt-Salt",
          "Pair-Setup-Encrypt-Info",
          @key_bytes
        )

      assert {:ok, opened} = Cipher.open(key, Cipher.message_nonce("PS-Msg06"), sealed)
      assert {:ok, inner} = Tlv8.decode(opened)
      assert {:ok, identifier} = Tlv8.fetch(inner, @identifier)
      assert {:ok, public} = Tlv8.fetch(inner, @public_key)
      assert {:ok, signature} = Tlv8.fetch(inner, @signature)

      assert identifier == "PiFi"
      assert public == Identity.public_key(context.dir)

      info =
        Hkdf.derive(
          @hash,
          session_key,
          "Pair-Setup-Accessory-Sign-Salt",
          "Pair-Setup-Accessory-Sign-Info",
          @key_bytes
        )

      assert Identity.verify(info <> identifier <> public, signature, public)
    end

    test "refuses a signature from somebody else's key", context do
      %{proven: proven, phone_keys: keys, session_key: session_key} = context
      impostor = Identity.pair(context.phone <> "-other")
      on_exit(fn -> File.rm_rf(context.phone <> "-other") end)

      request = m5(session_key, "telephone", %{keys | public: impostor.public}, context.phone)

      assert {:error, :bad_signature} =
               PairSetup.finish(proven, request, fn _id, _key -> :ok end, context.dir)
    end

    test "refuses data sealed with the wrong key", context do
      %{proven: proven, phone_keys: keys} = context
      request = m5(:crypto.strong_rand_bytes(64), "telephone", keys, context.phone)

      assert {:error, _reason} =
               PairSetup.finish(proven, request, fn _id, _key -> :ok end, context.dir)
    end

    test "stops when the caller will not remember the telephone", context do
      %{proven: proven, phone_keys: keys, session_key: session_key} = context
      request = m5(session_key, "telephone", keys, context.phone)

      assert {:error, :full} =
               PairSetup.finish(proven, request, fn _id, _key -> {:error, :full} end, context.dir)
    end
  end

  describe "refusing" do
    test "says which message failed" do
      assert {:ok, items} = Tlv8.decode(PairSetup.refusal(2))

      assert {:ok, <<0x02>>} = Tlv8.fetch(items, @state)
      assert {:ok, <<0x02>>} = Tlv8.fetch(items, @error)
    end
  end
end
