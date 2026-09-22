defmodule PiFi.Test.AirPlayPhone do
  @moduledoc """
  The telephone's half of an AirPlay pairing, for a test to be.

  **Written from the specification rather than from the code it tests.** The client's
  side of SRP is different arithmetic from the accessory's — it computes
  `S = (B - k·g^x)^(a + u·x)` where the accessory computes `S = (A·v^u)^b` — so the two
  arriving at the same key means the exchange is right rather than merely
  self-consistent.

  It also names its keys the way a controller does, which is the opposite way round from
  the accessory. That is the part most easily got wrong, and a test that named them the
  same way at both ends would agree with a receiver nothing else could talk to.
  """

  alias PiFi.AirPlay.Hkdf
  alias PiFi.AirPlay.PairSetup
  alias PiFi.AirPlay.SecureChannel
  alias PiFi.AirPlay.Srp
  alias PiFi.AirPlay.Tlv8

  @method 0x00
  @salt 0x02
  @public_key 0x03
  @proof 0x04
  @state 0x06
  @flags 0x13

  @hash :sha512
  @transient 0x10

  @doc """
  M1: ask to pair. `transient?: true` asks for the pairing an iPhone asks for.
  """
  @spec m1(keyword()) :: binary()
  def m1(options \\ []) do
    items = [{@method, Keyword.get(options, :method, <<0x00>>)}, {@state, <<0x01>>}]

    if Keyword.get(options, :transient?, false),
      do: Tlv8.encode(items ++ [{@flags, <<@transient>>}]),
      else: Tlv8.encode(items)
  end

  @doc """
  M3: answer the accessory's M2, proving the code was known.

  Gives the message and what the telephone worked out, so a test can check the two sides
  agree.
  """
  @spec m3(binary(), String.t() | nil) :: {binary(), map()}
  def m3(m2, code \\ nil) do
    code = code || PairSetup.transient_code()
    group = Srp.group_3072()

    {:ok, items} = Tlv8.decode(m2)
    {:ok, server_public} = Tlv8.fetch(items, @public_key)
    {:ok, salt} = Tlv8.fetch(items, @salt)

    server = Srp.value(server_public)
    private = Srp.private_key()
    client = power(group, group.generator, private)

    session_key = session_key(group, code, salt, client, server, private)
    proof = Srp.client_proof(group, @hash, Srp.username(), salt, client, server, session_key)

    message =
      Tlv8.encode([
        {@state, <<0x03>>},
        {@public_key, Srp.bytes(group, client)},
        {@proof, proof}
      ])

    {message,
     %{session_key: session_key, client: client, server: server, proof: proof, group: group}}
  end

  @doc """
  The channel the telephone talks on once pairing is done.

  **The keys are the other way round from the accessory's.** The controller writes with
  `Control-Write-Encryption-Key`, and the accessory reads with it.
  """
  @spec channel(binary()) :: SecureChannel.t()
  def channel(shared) do
    SecureChannel.new(%{
      read: control_key(shared, "Control-Read-Encryption-Key"),
      write: control_key(shared, "Control-Write-Encryption-Key")
    })
  end

  @doc "One control key, by the name the specification gives it."
  @spec control_key(binary(), String.t()) :: binary()
  def control_key(shared, info), do: Hkdf.derive(@hash, shared, "Control-Salt", info, 32)

  # S = (B - k·g^x)^(a + u·x) mod N. The accessory reaches the same number the other way.
  defp session_key(group, code, salt, client, server, private) do
    x = exponent(group, code, salt)
    k = multiplier(group)
    u = scrambler(group, client, server)

    base =
      Integer.mod(
        server - Integer.mod(k * power(group, group.generator, x), group.prime) + group.prime * k,
        group.prime
      )

    Srp.session_key(@hash, power(group, base, private + u * x))
  end

  defp exponent(group, code, salt) do
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

  defp power(group, base, exponent) do
    :crypto.mod_pow(
      :binary.encode_unsigned(base),
      :binary.encode_unsigned(exponent),
      :binary.encode_unsigned(group.prime)
    )
    |> :binary.decode_unsigned()
  end
end
