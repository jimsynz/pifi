defmodule PiFi.AirPlay.HkdfTest do
  use ExUnit.Case, async: true

  doctest PiFi.AirPlay.Hkdf

  alias PiFi.AirPlay.Hkdf

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
  defp unhex(text), do: Base.decode16!(text, case: :mixed)

  # **These are the published answers**, from RFC 5869. A key derivation checked only
  # against another implementation of mine would agree with my mistakes.
  describe "RFC 5869 test vectors" do
    test "case 1: SHA-256 with a salt and an info" do
      ikm = :binary.copy(<<0x0B>>, 22)
      salt = unhex("000102030405060708090A0B0C")
      info = unhex("F0F1F2F3F4F5F6F7F8F9")

      prk = Hkdf.extract(:sha256, salt, ikm)

      assert hex(prk) == "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"

      assert hex(Hkdf.expand(:sha256, prk, info, 42)) ==
               "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
    end

    # An empty salt means a salt of zeros as long as the hash. A reader that passed the
    # empty string straight to HMAC gets a different key and no complaint from anything.
    test "case 3: no salt and no info" do
      ikm = :binary.copy(<<0x0B>>, 22)

      prk = Hkdf.extract(:sha256, "", ikm)

      assert hex(prk) == "19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04"

      assert hex(Hkdf.expand(:sha256, prk, "", 42)) ==
               "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8"
    end
  end

  # **AirPlay uses SHA-512 and the RFC publishes no vector for it.** These came from an
  # independent implementation written from the standard, which agrees with the
  # published SHA-256 answers above — so the algorithm is right and this checks the
  # hash this firmware actually uses.
  describe "SHA-512, which is what pairing uses" do
    test "it agrees with an independent implementation" do
      ikm = :binary.copy(<<0x0B>>, 22)
      salt = unhex("000102030405060708090A0B0C")
      info = unhex("F0F1F2F3F4F5F6F7F8F9")

      assert hex(Hkdf.extract(:sha512, salt, ikm)) ==
               "665799823737ded04a88e47e54a5890bb2c3d247c7a4254a8e61350723590a26" <>
                 "c36238127d8661b88cf80ef802d57e2f7cebcf1e00e083848be19929c61b4237"

      assert hex(Hkdf.derive(:sha512, ikm, salt, info, 64)) ==
               "832390086cda71fb47625bb5ceb168e4c8e26a1a16ed34d9fc7fe92c14815793" <>
                 "38da362cb8d9f925d7cbcce0dff7098769cf15959867d571c1715450cb530137"
    end
  end

  describe "what it gives" do
    test "exactly the length asked for, whatever the hash" do
      for hash <- [:sha256, :sha512], length <- [1, 16, 31, 32, 33, 64, 200] do
        assert byte_size(Hkdf.derive(hash, "secret", "salt", "info", length)) == length
      end
    end

    # **`info` is what separates one use of a key from another.** Two derivations from
    # one secret that gave the same bytes would hand a pairing the same key twice.
    test "a different info gives unrelated bytes" do
      read = Hkdf.derive(:sha512, "secret", "salt", "read", 32)
      write = Hkdf.derive(:sha512, "secret", "salt", "write", 32)

      refute read == write
    end

    test "a shorter output is a prefix of a longer one" do
      short = Hkdf.derive(:sha512, "secret", "salt", "info", 16)
      long = Hkdf.derive(:sha512, "secret", "salt", "info", 64)

      assert binary_part(long, 0, 16) == short
    end

    # The counter is one byte, so 255 blocks is the ceiling and the standard says so.
    test "asking for more than the standard allows is an error and not a short answer" do
      assert_raise ArgumentError, fn -> Hkdf.expand(:sha256, "key", "info", 255 * 32 + 1) end
    end
  end
end
