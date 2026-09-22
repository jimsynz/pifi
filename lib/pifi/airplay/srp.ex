defmodule PiFi.AirPlay.Srp do
  @moduledoc """
  The SRP-6a exchange that Pair-Setup runs on, from the accessory's side.

  A person reads a code off the device and types it into their telephone. SRP proves
  each side knows it without either sending it, and leaves both holding the same secret.
  **Nothing here ever sends the code.**

  ## Why this is not `:crypto.generate_key(:srp, ...)`

  OTP has SRP, and it computes the multiplier `k` with SHA-1. AirPlay and HomeKit use
  SHA-512 throughout, so the built-in one agrees with the specification on the
  arithmetic and disagrees on the hash — which gives a `B` the telephone will not accept
  and no hint as to why.

  So the exchange is here and the arithmetic is `:crypto.mod_pow/3`, which is the part
  worth having from OTP.

  ## The hash and the group are arguments

  RFC 5054 publishes its test vector with SHA-1 and a 1024-bit group, and AirPlay uses
  SHA-512 and 3072 bits. Both are arguments so that the published answers can be checked
  against this code rather than against a second implementation of it. See the tests.

  ## Padding is load-bearing

  `k` and `u` hash numbers that are padded to the length of the prime. A value that
  happens to have a leading zero byte hashes differently unpadded, so an implementation
  without the padding works until it does not, at a rate of about one exchange in 256.
  """

  # RFC 5054 Appendix A, the 3072-bit group. Verified 3072 bits and prime before it was
  # written down.
  @prime_3072 """
  FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74
  020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437
  4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED
  EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05
  98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB
  9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B
  E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718
  3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33
  A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7
  ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864
  D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2
  08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
  """

  @typedoc "A prime and a generator, as the numbers they are."
  @type group :: %{prime: pos_integer(), generator: pos_integer()}

  @doc """
  The group that AirPlay pairing uses: RFC 5054's 3072-bit prime, generator 5.

      iex> PiFi.AirPlay.Srp.group_3072().generator
      5
  """
  @spec group_3072() :: group()
  def group_3072 do
    %{prime: @prime_3072 |> String.replace(~r/\s/, "") |> String.to_integer(16), generator: 5}
  end

  @doc """
  The name the telephone uses for a pairing.

      iex> PiFi.AirPlay.Srp.username()
      "Pair-Setup"
  """
  @spec username() :: String.t()
  def username, do: "Pair-Setup"

  @doc """
  What the accessory keeps instead of the code.

  `x` is derived from the salt and the code, and the verifier is `g^x mod N`. **The
  verifier cannot be turned back into the code**, which is the point: it can be kept,
  and a telephone that knows the code can still prove it.
  """
  @spec verifier(group(), atom(), String.t(), String.t(), binary()) :: pos_integer()
  def verifier(group, hash, username, password, salt) do
    :crypto.mod_pow(
      number(group.generator),
      number(private_key(hash, username, password, salt)),
      number(group.prime)
    )
    |> decode()
  end

  @doc """
  The public value the accessory sends, `B = kv + g^b mod N`.

  **It is not `g^b`,** which is the ordinary Diffie-Hellman value. The verifier is mixed
  in so that a telephone cannot pretend to know the code by choosing its own side of the
  exchange.
  """
  @spec public_key(group(), atom(), pos_integer(), pos_integer()) :: pos_integer()
  def public_key(group, hash, verifier, private) do
    k = multiplier(group, hash)

    gb =
      :crypto.mod_pow(number(group.generator), number(private), number(group.prime)) |> decode()

    Integer.mod(k * verifier + gb, group.prime)
  end

  @doc """
  The secret both sides arrive at, `S = (A · v^u)^b mod N`.

  **A client public value that is zero modulo the prime is refused.** It would make the
  secret zero whatever the code was, which is a telephone claiming to have paired
  without knowing anything.
  """
  @spec secret(group(), atom(), pos_integer(), pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, :bad_client_public}
  def secret(group, hash, client_public, server_public, verifier, private) do
    if Integer.mod(client_public, group.prime) == 0 do
      {:error, :bad_client_public}
    else
      u = scrambler(group, hash, client_public, server_public)
      vu = :crypto.mod_pow(number(verifier), number(u), number(group.prime)) |> decode()
      base = Integer.mod(client_public * vu, group.prime)

      {:ok, :crypto.mod_pow(number(base), number(private), number(group.prime)) |> decode()}
    end
  end

  @doc """
  The session key, which is the hash of the secret.

  **AirPlay hashes the secret once and does not interleave it**, which older SRP
  descriptions do. The telephone expects the plain hash.
  """
  @spec session_key(atom(), pos_integer()) :: binary()
  def session_key(hash, secret), do: :crypto.hash(hash, number(secret))

  @doc """
  What the telephone must send to prove it knew the code.

  A pairing compares this with what arrived, and a mismatch is a wrong code and the end
  of the exchange.
  """
  @spec client_proof(
          group(),
          atom(),
          String.t(),
          binary(),
          pos_integer(),
          pos_integer(),
          binary()
        ) ::
          binary()
  def client_proof(group, hash, username, salt, client_public, server_public, session_key) do
    n = :crypto.hash(hash, number(group.prime))
    g = :crypto.hash(hash, number(group.generator))

    :crypto.hash(
      hash,
      :crypto.exor(n, pad(g, byte_size(n))) <>
        :crypto.hash(hash, username) <>
        salt <> padded(group, client_public) <> padded(group, server_public) <> session_key
    )
  end

  @doc """
  What the accessory sends back, so the telephone knows it was not talking to nothing.
  """
  @spec server_proof(group(), pos_integer(), binary(), binary(), atom()) :: binary()
  def server_proof(group, client_public, client_proof, session_key, hash) do
    :crypto.hash(hash, padded(group, client_public) <> client_proof <> session_key)
  end

  @doc """
  A value as the wire carries it: big-endian, and **padded to the width of the prime**.

  The padding is not decoration. `A` and `B` go into the hashes that both sides compute,
  and a value that lost its leading zero would hash differently at each end — which
  happens for one exchange in about two hundred and fifty, so it passes a test and fails
  on a board.

      iex> group = PiFi.AirPlay.Srp.group_3072()
      iex> PiFi.AirPlay.Srp.bytes(group, 1) |> byte_size()
      384
  """
  @spec bytes(group(), non_neg_integer()) :: binary()
  def bytes(group, value), do: padded(group, value)

  @doc """
  A value read off the wire.

      iex> PiFi.AirPlay.Srp.value(<<1, 0>>)
      256
  """
  @spec value(binary()) :: non_neg_integer()
  def value(bytes), do: decode(bytes)

  @doc """
  A private value for one exchange.

  It is 32 bytes of randomness, which is what RFC 5054 asks for, and it never leaves
  this device.
  """
  @spec private_key() :: pos_integer()
  def private_key, do: 32 |> :crypto.strong_rand_bytes() |> decode()

  # x = H(salt | H(username | ":" | password)). The inner hash is what keeps the code
  # out of everything that follows.
  defp private_key(hash, username, password, salt) do
    inner = :crypto.hash(hash, username <> ":" <> password)

    :crypto.hash(hash, salt <> inner) |> decode()
  end

  # k = H(N | PAD(g)), and the padding is what makes this agree with every other
  # implementation.
  defp multiplier(group, hash) do
    :crypto.hash(hash, number(group.prime) <> padded(group, group.generator)) |> decode()
  end

  # u = H(PAD(A) | PAD(B)).
  defp scrambler(group, hash, client_public, server_public) do
    :crypto.hash(hash, padded(group, client_public) <> padded(group, server_public)) |> decode()
  end

  defp padded(group, value) do
    pad(number(value), byte_size(number(group.prime)))
  end

  defp pad(bytes, size) when byte_size(bytes) >= size, do: bytes
  defp pad(bytes, size), do: :binary.copy(<<0>>, size - byte_size(bytes)) <> bytes

  defp number(value) when is_integer(value), do: :binary.encode_unsigned(value)
  defp number(value) when is_binary(value), do: value

  defp decode(bytes), do: :binary.decode_unsigned(bytes)
end
