defmodule PiFi.AirPlay.Hkdf do
  @moduledoc """
  The key derivation that AirPlay pairing runs on, from RFC 5869.

  Pair-Setup and Pair-Verify derive every key they use this way: the shared secret from
  SRP or from Curve25519 goes in, and the keys that encrypt the rest of the exchange
  come out. **OTP has no HKDF**, and it is two HMACs in a loop, so this is it.

  It is here rather than in a dependency because the whole of it is twenty lines and
  because a wrong answer is a handshake that fails somewhere else entirely. Twenty lines
  with the published vectors beside them is easier to trust than a package.

  ## Extract, then expand

  **Extract** takes whatever entropy there is and concentrates it into one
  pseudo-random key: `HMAC(salt, input)`, with the salt as the key rather than the
  message, which reads backwards and is what the standard says.

  **Expand** stretches that into as many bytes as are wanted, by chaining HMACs and
  counting. A caller almost always wants `derive/5`, which does both.

  ## SHA-512 here, and SHA-256 in the published vectors

  AirPlay uses SHA-512. RFC 5869 publishes its test vectors for SHA-256 and SHA-1, so
  the tests check this against the published vectors on SHA-256 and against an
  independent implementation on SHA-512. Checking only the algorithm this firmware uses
  would leave the published answers unused, and checking only the published ones would
  leave the algorithm it uses untested.
  """

  @typedoc "A hash that `:crypto` knows and HKDF is defined for."
  @type hash :: :sha | :sha256 | :sha384 | :sha512

  @doc """
  Concentrate the entropy of `input` into one pseudo-random key.

  **An empty salt means a salt of zeros**, as long as the hash, which is the standard
  saying so rather than a convenience.

      iex> PiFi.AirPlay.Hkdf.extract(:sha256, Base.decode16!("000102030405060708090A0B0C"), :binary.copy(<<0x0B>>, 22)) |> Base.encode16(case: :lower)
      "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"
  """
  @spec extract(hash(), binary(), binary()) :: binary()
  def extract(hash, salt, input) do
    :crypto.mac(:hmac, hash, zeroed(hash, salt), input)
  end

  @doc """
  Stretch a pseudo-random key into `length` bytes.

  `info` separates one use of a key from another: two derivations from one secret with
  different `info` give unrelated keys, which is how a pairing gets a read key and a
  write key out of one exchange.
  """
  @spec expand(hash(), binary(), binary(), pos_integer()) :: binary()
  def expand(hash, key, info, length) do
    hash
    |> blocks(key, info, length)
    |> binary_part(0, length)
  end

  @doc """
  Extract and then expand, which is what a caller almost always wants.

      iex> secret = :binary.copy(<<0x0B>>, 22)
      iex> salt = Base.decode16!("000102030405060708090A0B0C")
      iex> info = Base.decode16!("F0F1F2F3F4F5F6F7F8F9")
      iex> PiFi.AirPlay.Hkdf.derive(:sha256, secret, salt, info, 42) |> Base.encode16(case: :lower)
      "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
  """
  @spec derive(hash(), binary(), binary(), binary(), pos_integer()) :: binary()
  def derive(hash, secret, salt, info, length) do
    hash
    |> extract(salt, secret)
    |> then(&expand(hash, &1, info, length))
  end

  # **The counter is one byte, so 255 blocks is the ceiling** and the standard says so.
  # Nothing in AirPlay asks for more than 64 bytes, and a caller that asked for 16 kB of
  # key material has made a mistake worth hearing about.
  defp blocks(hash, key, info, length) do
    size = :crypto.hash(hash, "") |> byte_size()
    count = ceil(length / size)

    if count > 255 do
      raise ArgumentError, "HKDF cannot give more than #{255 * size} bytes of #{hash}"
    end

    Enum.reduce(1..count, {<<>>, <<>>}, fn counter, {previous, all} ->
      block = :crypto.mac(:hmac, hash, key, previous <> info <> <<counter>>)

      {block, all <> block}
    end)
    |> elem(1)
  end

  defp zeroed(hash, <<>>), do: :binary.copy(<<0>>, byte_size(:crypto.hash(hash, "")))
  defp zeroed(_hash, salt), do: salt
end
