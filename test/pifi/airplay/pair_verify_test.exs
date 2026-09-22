defmodule PiFi.AirPlay.PairVerifyTest do
  use ExUnit.Case, async: true

  alias PiFi.AirPlay.Cipher
  alias PiFi.AirPlay.Hkdf
  alias PiFi.AirPlay.Identity
  alias PiFi.AirPlay.PairVerify
  alias PiFi.AirPlay.Tlv8

  @identifier 0x01
  @public_key 0x03
  @encrypted_data 0x05
  @state 0x06
  @error 0x07
  @signature 0x0A

  setup do
    dir = Path.join(System.tmp_dir!(), "pair-verify-#{System.unique_integer([:positive])}")
    phone_dir = dir <> "-phone"

    on_exit(fn ->
      File.rm_rf(dir)
      File.rm_rf(phone_dir)
    end)

    %{dir: dir, phone: phone_dir, phone_id: "telephone", device_id: "PiFi"}
  end

  defp control_key(shared, info), do: Hkdf.derive(:sha512, shared, "Control-Salt", info, 32)

  # **The telephone's half, written from the specification rather than from the code it
  # is testing.** It signs in the mirrored order, which is the thing most likely to be
  # got wrong on either side.
  defp phone_keys do
    {public, private} = :crypto.generate_key(:ecdh, :x25519)
    %{public: public, private: private}
  end

  defp phone_m3(phone, reply, context) do
    {:ok, items} = Tlv8.decode(reply)
    {:ok, device_public} = Tlv8.fetch(items, @public_key)

    shared = :crypto.compute_key(:ecdh, device_public, phone.private, :x25519)

    session_key =
      Hkdf.derive(:sha512, shared, "Pair-Verify-Encrypt-Salt", "Pair-Verify-Encrypt-Info", 32)

    signature =
      Identity.sign(phone.public <> context.phone_id <> device_public, context.phone)

    sealed =
      Cipher.seal(
        session_key,
        Cipher.message_nonce("PV-Msg03"),
        Tlv8.encode([{@identifier, context.phone_id}, {@signature, signature}])
      )

    {Tlv8.encode([{@state, <<0x03>>}, {@encrypted_data, sealed}]), shared}
  end

  defp paired(context) do
    known = Identity.public_key(context.phone)

    fn
      id when id == context.phone_id -> {:ok, known}
      _other -> :error
    end
  end

  describe "a verification that succeeds" do
    test "both sides arrive at the same connection keys", context do
      phone = phone_keys()
      m1 = Tlv8.encode([{@state, <<0x01>>}, {@public_key, phone.public}])

      assert {:ok, m2, exchange} = PairVerify.start(context.device_id, m1, context.dir)

      {m3, phone_shared} = phone_m3(phone, m2, context)

      assert {:ok, m4, keys} = PairVerify.finish(exchange, m3, paired(context))

      # **The two names are the telephone's and this is the accessory, so they cross
      # over.** What the telephone writes with is what this device reads with. An
      # earlier version of this test asserted the names at face value, which agreed
      # with the code and with nothing else: both were wrong the same way, and every
      # message after the handshake would have failed to authenticate.
      assert keys.read == control_key(phone_shared, "Control-Write-Encryption-Key")
      assert keys.write == control_key(phone_shared, "Control-Read-Encryption-Key")

      assert {:ok, items} = Tlv8.decode(m4)
      assert {:ok, <<0x04>>} = Tlv8.fetch(items, @state)
      assert :error = Tlv8.fetch(items, @error)
    end

    # **Reading and writing must not share a key.** One key both ways would let a
    # message this device sent be replayed back to it as one it received.
    test "the two directions get different keys", context do
      phone = phone_keys()
      m1 = Tlv8.encode([{@state, <<0x01>>}, {@public_key, phone.public}])

      {:ok, m2, exchange} = PairVerify.start(context.device_id, m1, context.dir)
      {m3, _shared} = phone_m3(phone, m2, context)

      assert {:ok, _m4, keys} = PairVerify.finish(exchange, m3, paired(context))

      refute keys.read == keys.write
    end

    # The signature is what stops somebody in the middle: the shared secret alone
    # proves only that the other side can do arithmetic.
    test "M2 carries a signature the telephone can check", context do
      phone = phone_keys()
      m1 = Tlv8.encode([{@state, <<0x01>>}, {@public_key, phone.public}])

      {:ok, m2, _exchange} = PairVerify.start(context.device_id, m1, context.dir)

      {:ok, items} = Tlv8.decode(m2)
      {:ok, device_public} = Tlv8.fetch(items, @public_key)
      {:ok, sealed} = Tlv8.fetch(items, @encrypted_data)

      shared = :crypto.compute_key(:ecdh, device_public, phone.private, :x25519)

      key =
        Hkdf.derive(:sha512, shared, "Pair-Verify-Encrypt-Salt", "Pair-Verify-Encrypt-Info", 32)

      assert {:ok, plain} = Cipher.open(key, Cipher.message_nonce("PV-Msg02"), sealed)
      assert {:ok, inner} = Tlv8.decode(plain)
      assert {:ok, signature} = Tlv8.fetch(inner, @signature)

      assert Identity.verify(
               device_public <> context.device_id <> phone.public,
               signature,
               Identity.public_key(context.dir)
             )
    end
  end

  describe "what it refuses" do
    setup context do
      phone = phone_keys()
      m1 = Tlv8.encode([{@state, <<0x01>>}, {@public_key, phone.public}])
      {:ok, m2, exchange} = PairVerify.start(context.device_id, m1, context.dir)

      Map.merge(context, %{phone_keys: phone, m2: m2, exchange: exchange})
    end

    # **A telephone nobody paired is an identifier with no key.** That is the whole of
    # the access control.
    test "a telephone that was never paired", context do
      {m3, _shared} = phone_m3(context.phone_keys, context.m2, context)

      assert {:error, _reply, :not_paired} =
               PairVerify.finish(context.exchange, m3, fn _id -> :error end)
    end

    # Somebody with the right identifier and the wrong key is the case this exists for.
    test "a signature from the wrong key", context do
      other = context.dir <> "-impostor"
      on_exit(fn -> File.rm_rf(other) end)

      {m3, _shared} = phone_m3(context.phone_keys, context.m2, %{context | phone: other})

      assert {:error, _reply, :bad_signature} =
               PairVerify.finish(context.exchange, m3, paired(context))
    end

    test "a message that does not decrypt", context do
      m3 = Tlv8.encode([{@state, <<0x03>>}, {@encrypted_data, :crypto.strong_rand_bytes(80)}])

      assert {:error, _reply, :bad_tag} =
               PairVerify.finish(context.exchange, m3, paired(context))
    end

    test "a message with nothing in it", context do
      assert {:error, _reply, {:missing, @encrypted_data}} =
               PairVerify.finish(
                 context.exchange,
                 Tlv8.encode([{@state, <<0x03>>}]),
                 paired(context)
               )
    end

    test "an M1 with no public key", context do
      assert {:error, {:missing, @public_key}} =
               PairVerify.start(context.device_id, Tlv8.encode([{@state, <<0x01>>}]), context.dir)
    end

    # **A refusal says only that it failed.** Saying which step, or whether the
    # identifier was known, tells somebody guessing which half of their guess was right.
    test "every refusal looks the same", context do
      {m3, _shared} = phone_m3(context.phone_keys, context.m2, context)

      {:error, unpaired, _} = PairVerify.finish(context.exchange, m3, fn _ -> :error end)

      other = context.dir <> "-impostor2"
      on_exit(fn -> File.rm_rf(other) end)
      {bad_m3, _} = phone_m3(context.phone_keys, context.m2, %{context | phone: other})
      {:error, forged, _} = PairVerify.finish(context.exchange, bad_m3, paired(context))

      assert unpaired == forged
      assert {:ok, items} = Tlv8.decode(unpaired)
      assert {:ok, <<0x02>>} = Tlv8.fetch(items, @error)
    end
  end
end
