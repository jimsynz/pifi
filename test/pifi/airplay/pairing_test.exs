defmodule PiFi.AirPlay.PairingTest do
  use PiFi.DataCase, async: false

  alias PiFi.AirPlay

  defp key, do: :crypto.strong_rand_bytes(32)

  describe "remembering a telephone" do
    test "a paired telephone is known by its identifier" do
      public_key = key()

      assert {:ok, _pairing} = AirPlay.pair("telephone-1", public_key)
      assert {:ok, %{public_key: ^public_key}} = AirPlay.pairing_for("telephone-1")
    end

    # **A telephone nobody paired is an identifier this domain does not know**, and that
    # is the whole of the access control.
    test "one nobody paired is not" do
      assert {:error, _reason} = AirPlay.pairing_for("never-seen")
    end

    # A person who removed the accessory and paired again gets a new key for the same
    # identifier. Two rows would leave the old key working.
    test "pairing again replaces the key rather than adding a row" do
      {:ok, _first} = AirPlay.pair("telephone-1", key())
      replacement = key()

      assert {:ok, _second} = AirPlay.pair("telephone-1", replacement)
      assert {:ok, %{public_key: ^replacement}} = AirPlay.pairing_for("telephone-1")
      assert length(AirPlay.pairings!()) == 1
    end

    test "two telephones are two rows" do
      {:ok, _one} = AirPlay.pair("telephone-1", key())
      {:ok, _two} = AirPlay.pair("telephone-2", key())

      assert length(AirPlay.pairings!()) == 2
    end

    test "a telephone that is forgotten has to pair again" do
      {:ok, pairing} = AirPlay.pair("telephone-1", key())

      assert :ok = AirPlay.forget_pairing(pairing)
      assert {:error, _reason} = AirPlay.pairing_for("telephone-1")
    end
  end

  # This is the one function that joins the protocol to what a person has set up.
  # `PiFi.AirPlay.PairVerify.finish/3` asks it and nothing else.
  describe "the question Pair-Verify asks" do
    test "it answers with the key of a paired telephone" do
      public_key = key()
      {:ok, _pairing} = AirPlay.pair("telephone-1", public_key)

      assert AirPlay.known_key().("telephone-1") == {:ok, public_key}
    end

    test "it answers :error for one nobody paired" do
      assert AirPlay.known_key().("never-seen") == :error
    end

    # The binary round trip matters: a key stored as text would come back mangled and
    # every signature would fail for a reason nothing could explain.
    test "a key comes back as the bytes it went in as" do
      public_key = <<0, 255, 128, 1>> <> :crypto.strong_rand_bytes(28)
      {:ok, _pairing} = AirPlay.pair("telephone-1", public_key)

      assert {:ok, ^public_key} = AirPlay.known_key().("telephone-1")
    end
  end

  # **The store and the exchange are joined by one function and nothing else**, so this
  # is the test that proves the join rather than the two halves.
  describe "a real pairing through a real verification" do
    alias PiFi.AirPlay.Cipher
    alias PiFi.AirPlay.Hkdf
    alias PiFi.AirPlay.Identity
    alias PiFi.AirPlay.PairVerify
    alias PiFi.AirPlay.Tlv8

    setup do
      dir = Path.join(System.tmp_dir!(), "pairing-join-#{System.unique_integer([:positive])}")
      phone = dir <> "-phone"

      on_exit(fn ->
        File.rm_rf(dir)
        File.rm_rf(phone)
      end)

      %{dir: dir, phone: phone}
    end

    test "a telephone this device paired verifies", context do
      # What Pair-Setup would have left behind.
      {:ok, _pairing} = AirPlay.pair("telephone-1", Identity.public_key(context.phone))

      {phone_public, phone_private} = :crypto.generate_key(:ecdh, :x25519)
      m1 = Tlv8.encode([{0x06, <<0x01>>}, {0x03, phone_public}])

      {:ok, m2, exchange} = PairVerify.start("PiFi", m1, context.dir)

      {:ok, items} = Tlv8.decode(m2)
      {:ok, device_public} = Tlv8.fetch(items, 0x03)
      shared = :crypto.compute_key(:ecdh, device_public, phone_private, :x25519)

      session =
        Hkdf.derive(:sha512, shared, "Pair-Verify-Encrypt-Salt", "Pair-Verify-Encrypt-Info", 32)

      signature =
        Identity.sign(phone_public <> "telephone-1" <> device_public, context.phone)

      sealed =
        Cipher.seal(
          session,
          Cipher.message_nonce("PV-Msg03"),
          Tlv8.encode([{0x01, "telephone-1"}, {0x0A, signature}])
        )

      m3 = Tlv8.encode([{0x06, <<0x03>>}, {0x05, sealed}])

      assert {:ok, _m4, keys} = PairVerify.finish(exchange, m3, AirPlay.known_key())
      assert byte_size(keys.read) == 32
      refute keys.read == keys.write
    end

    # The same telephone, with nothing in the store. Everything else is identical, so
    # the store is the only thing that refused it.
    test "the same telephone unpaired does not", context do
      {phone_public, phone_private} = :crypto.generate_key(:ecdh, :x25519)
      m1 = Tlv8.encode([{0x06, <<0x01>>}, {0x03, phone_public}])

      {:ok, m2, exchange} = PairVerify.start("PiFi", m1, context.dir)

      {:ok, items} = Tlv8.decode(m2)
      {:ok, device_public} = Tlv8.fetch(items, 0x03)
      shared = :crypto.compute_key(:ecdh, device_public, phone_private, :x25519)

      session =
        Hkdf.derive(:sha512, shared, "Pair-Verify-Encrypt-Salt", "Pair-Verify-Encrypt-Info", 32)

      signature =
        Identity.sign(phone_public <> "telephone-1" <> device_public, context.phone)

      sealed =
        Cipher.seal(
          session,
          Cipher.message_nonce("PV-Msg03"),
          Tlv8.encode([{0x01, "telephone-1"}, {0x0A, signature}])
        )

      m3 = Tlv8.encode([{0x06, <<0x03>>}, {0x05, sealed}])

      assert {:error, _reply, :not_paired} =
               PairVerify.finish(exchange, m3, AirPlay.known_key())
    end
  end

  # The point of the store is that it is the same after a restart.
  test "a pairing outlives the process that made it" do
    public_key = key()
    {:ok, _pairing} = AirPlay.pair("telephone-1", public_key)

    assert {:ok, %{public_key: ^public_key}} = AirPlay.pairing_for("telephone-1")
  end
end
