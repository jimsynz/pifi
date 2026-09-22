defmodule PiFi.AirPlay.CipherTest do
  use ExUnit.Case, async: true

  doctest PiFi.AirPlay.Cipher

  alias PiFi.AirPlay.Cipher

  defp unhex(text), do: text |> String.replace(~r/\s/, "") |> Base.decode16!(case: :mixed)

  # **RFC 8439 section 2.8.2, the published vector.** This checks that `:crypto` is
  # being driven correctly — the arguments are in the right order and the tag is the
  # tag — rather than checking my code against itself.
  describe "RFC 8439 test vector" do
    setup do
      %{
        key: unhex("808182838485868788898A8B8C8D8E8F909192939495969798999A9B9C9D9E9F"),
        nonce: unhex("070000004041424344454647"),
        aad: unhex("50515253C0C1C2C3C4C5C6C7"),
        plaintext:
          "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
      }
    end

    test "it produces the published ciphertext and tag", context do
      sealed = Cipher.seal(context.key, context.nonce, context.plaintext, context.aad)

      expected_tag = unhex("1AE10B594F09E26A7E902ECBD0600691")
      tag = binary_part(sealed, byte_size(sealed) - 16, 16)

      assert tag == expected_tag

      assert binary_part(sealed, 0, 16) == unhex("D31A8D34648E60DB7B86AFBC53EF7EC2")
    end

    test "it reads its own published ciphertext back" do
      key = unhex("808182838485868788898A8B8C8D8E8F909192939495969798999A9B9C9D9E9F")
      nonce = unhex("070000004041424344454647")
      aad = unhex("50515253C0C1C2C3C4C5C6C7")

      text =
        "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."

      sealed = Cipher.seal(key, nonce, text, aad)

      assert {:ok, ^text} = Cipher.open(key, nonce, sealed, aad)
    end
  end

  # **The label is padded on the left**, and padding it on the right gives a nonce that
  # is wrong for every message, with an authentication failure and nothing to point at.
  describe "the nonce of a pairing message" do
    test "it pads on the left" do
      assert Cipher.message_nonce("PS-Msg05") == <<0, 0, 0, 0, "PS-Msg05">>
      assert Cipher.message_nonce("PV-Msg02") == <<0, 0, 0, 0, "PV-Msg02">>
    end

    test "it is always twelve bytes" do
      for label <- ["", "a", "PS-Msg01", "123456789012"] do
        assert byte_size(Cipher.message_nonce(label)) == 12
      end
    end

    test "two different steps get two different nonces" do
      refute Cipher.message_nonce("PS-Msg05") == Cipher.message_nonce("PS-Msg06")
    end
  end

  # **The counter is little-endian**, which is the one place the byte order flips in a
  # protocol otherwise full of big-endian numbers.
  describe "the nonce of a session message" do
    test "it counts in little-endian" do
      assert Cipher.counter_nonce(0) == <<0::96>>
      assert Cipher.counter_nonce(1) == <<0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0>>
      assert Cipher.counter_nonce(256) == <<0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0>>
    end

    test "it is always twelve bytes" do
      for counter <- [0, 1, 255, 256, 65_535, 4_294_967_296] do
        assert byte_size(Cipher.counter_nonce(counter)) == 12
      end
    end

    # A counter that repeated would reuse a nonce, which is the one thing this
    # algorithm must never do.
    test "every counter gives a different nonce" do
      nonces = Enum.map(0..500, &Cipher.counter_nonce/1)

      assert length(Enum.uniq(nonces)) == 501
    end
  end

  describe "sealing and opening" do
    setup do
      %{key: :crypto.strong_rand_bytes(32), nonce: Cipher.counter_nonce(7)}
    end

    test "what is sealed opens", context do
      for size <- [0, 1, 16, 17, 1000] do
        plaintext = :crypto.strong_rand_bytes(size)
        sealed = Cipher.seal(context.key, context.nonce, plaintext)

        assert {:ok, ^plaintext} = Cipher.open(context.key, context.nonce, sealed)
      end
    end

    test "the tag goes on the end and costs sixteen bytes", context do
      sealed = Cipher.seal(context.key, context.nonce, "abc")

      assert byte_size(sealed) == 3 + Cipher.tag_bytes()
    end

    # Every byte of this arrived over a network.
    test "a damaged message does not authenticate", context do
      sealed = Cipher.seal(context.key, context.nonce, "the message")
      <<first, rest::binary>> = sealed
      damaged = <<Bitwise.bxor(first, 1), rest::binary>>

      assert {:error, :bad_tag} = Cipher.open(context.key, context.nonce, damaged)
    end

    test "a message opened with the wrong nonce does not authenticate", context do
      sealed = Cipher.seal(context.key, context.nonce, "the message")

      assert {:error, :bad_tag} = Cipher.open(context.key, Cipher.counter_nonce(8), sealed)
    end

    test "a message opened with the wrong key does not authenticate", context do
      sealed = Cipher.seal(context.key, context.nonce, "the message")

      assert {:error, :bad_tag} =
               Cipher.open(:crypto.strong_rand_bytes(32), context.nonce, sealed)
    end

    # The associated data is authenticated but not encrypted, so changing it has to
    # break the tag or it is not doing its job.
    test "associated data that changed does not authenticate", context do
      sealed = Cipher.seal(context.key, context.nonce, "the message", "length")

      assert {:error, :bad_tag} = Cipher.open(context.key, context.nonce, sealed, "other")
    end

    test "a message too short to hold a tag says so rather than failing oddly", context do
      assert {:error, :too_short} = Cipher.open(context.key, context.nonce, "short")
    end
  end
end
