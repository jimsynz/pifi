defmodule PiFi.AirPlay.PairVerify do
  @moduledoc """
  The exchange that runs on every connection after a pairing.

  Pair-Setup happens once, when a person types a code. **Pair-Verify happens every time
  a telephone connects**, and it does two things: it proves each side still holds the
  long-term key it had at pairing, and it leaves both with fresh keys for this
  connection alone.

  It is a Curve25519 exchange with an Ed25519 signature over it. The signature is what
  stops somebody in the middle: the shared secret alone proves only that the other side
  can do arithmetic.

  ## Four messages, and the accessory answers two of them

  - **M1** the telephone sends its ephemeral public key.
  - **M2** this device answers with its own, and with a signature — encrypted — over
    both keys and its identifier. `start/2` builds it.
  - **M3** the telephone sends the same shape back, and this device checks it.
    `finish/3` reads it.
  - **M4** this device says it is satisfied, and both sides switch to the new keys.

  ## What the signature covers, and the order

  Each side signs its **own** ephemeral key, then its identifier, then the **other**
  side's ephemeral key. The order is not symmetric and getting it backwards gives a
  signature the other side rejects with nothing to say about why.

  ## The keys that come out

  Reading and writing get different keys, derived from the same secret with different
  info strings. **A connection that used one key both ways** would let a message this
  device sent be replayed back to it as one it received.

  ## What this does not do

  It does not know which telephones are paired. `finish/3` takes a function that answers
  "what is the long-term key of this identifier", because that is a question about what
  a person has set up and not about the protocol. A telephone that is not paired is an
  identifier that function does not know.
  """

  alias PiFi.AirPlay.Cipher
  alias PiFi.AirPlay.Hkdf
  alias PiFi.AirPlay.Identity
  alias PiFi.AirPlay.Tlv8

  # The HomeKit TLV types that this exchange uses.
  @identifier 0x01
  @public_key 0x03
  @encrypted_data 0x05
  @state 0x06
  @error 0x07
  @signature 0x0A

  @error_authentication <<0x02>>

  @verify_salt "Pair-Verify-Encrypt-Salt"
  @verify_info "Pair-Verify-Encrypt-Info"

  @control_salt "Control-Salt"
  @read_info "Control-Read-Encryption-Key"
  @write_info "Control-Write-Encryption-Key"

  @key_bytes 32

  defmodule Exchange do
    @moduledoc "What the accessory has to remember between M2 and M3."

    @type t :: %__MODULE__{
            private: binary(),
            public: binary(),
            peer_public: binary(),
            session_key: binary(),
            shared: binary()
          }

    defstruct [:private, :public, :peer_public, :session_key, :shared]
  end

  @doc """
  Answer M1 with M2.

  `identifier` is what this device calls itself — the same one a telephone saw when it
  paired.
  """
  @spec start(binary(), binary(), Path.t()) ::
          {:ok, binary(), Exchange.t()} | {:error, term()}
  def start(identifier, request, data_dir \\ "/root") do
    with {:ok, items} <- Tlv8.decode(request),
         {:ok, peer_public} <- fetch(items, @public_key) do
      {public, private} = :crypto.generate_key(:ecdh, :x25519)
      shared = :crypto.compute_key(:ecdh, peer_public, private, :x25519)
      session_key = Hkdf.derive(:sha512, shared, @verify_salt, @verify_info, @key_bytes)

      # **Own key, then identifier, then theirs.** The order is not symmetric.
      signature = Identity.sign(public <> identifier <> peer_public, data_dir)

      sealed =
        Cipher.seal(
          session_key,
          Cipher.message_nonce("PV-Msg02"),
          Tlv8.encode([{@identifier, identifier}, {@signature, signature}])
        )

      reply = Tlv8.encode([{@state, <<0x02>>}, {@public_key, public}, {@encrypted_data, sealed}])

      {:ok, reply,
       %Exchange{
         private: private,
         public: public,
         peer_public: peer_public,
         session_key: session_key,
         shared: shared
       }}
    end
  end

  @doc """
  Read M3 and answer M4.

  `paired` answers what long-term key belongs to an identifier, and `:error` for one it
  does not know. **That is the whole of the access control**: a telephone nobody paired
  is an identifier with no key.

  It gives back the keys for the connection: `read` for what arrives and `write` for
  what leaves.
  """
  @spec finish(Exchange.t(), binary(), (binary() -> {:ok, binary()} | :error)) ::
          {:ok, binary(), %{read: binary(), write: binary()}} | {:error, binary(), term()}
  def finish(%Exchange{} = exchange, request, paired) do
    with {:ok, items} <- decoded(request),
         {:ok, sealed} <- fetched(items, @encrypted_data),
         {:ok, plain} <- opened(exchange, sealed),
         {:ok, inner} <- decoded(plain),
         {:ok, identifier} <- fetched(inner, @identifier),
         {:ok, signature} <- fetched(inner, @signature),
         {:ok, peer_key} <- known(paired, identifier),
         :ok <- signed(exchange, identifier, signature, peer_key) do
      {:ok, Tlv8.encode([{@state, <<0x04>>}]), keys(exchange)}
    else
      {:error, reason} -> {:error, refusal(), reason}
    end
  end

  @doc """
  The TLV8 that says a verification failed.

  **It says only that it failed.** A reply that said which step, or whether the
  identifier was known, would tell somebody guessing which half of their guess was
  right.
  """
  @spec refusal() :: binary()
  def refusal, do: Tlv8.encode([{@state, <<0x04>>}, {@error, @error_authentication}])

  defp keys(%Exchange{shared: shared}) do
    %{
      read: Hkdf.derive(:sha512, shared, @control_salt, @read_info, @key_bytes),
      write: Hkdf.derive(:sha512, shared, @control_salt, @write_info, @key_bytes)
    }
  end

  defp decoded(bytes) do
    case Tlv8.decode(bytes) do
      {:ok, items} -> {:ok, items}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetched(items, type) do
    case Tlv8.fetch(items, type) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing, type}}
    end
  end

  defp fetch(items, type), do: fetched(items, type)

  defp opened(%Exchange{session_key: key}, sealed) do
    Cipher.open(key, Cipher.message_nonce("PV-Msg03"), sealed)
  end

  defp known(paired, identifier) do
    case paired.(identifier) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :not_paired}
    end
  end

  # **Their key, then their identifier, then ours**, which is the mirror of what this
  # device signed and not the same order.
  defp signed(%Exchange{} = exchange, identifier, signature, peer_key) do
    message = exchange.peer_public <> identifier <> exchange.public

    if Identity.verify(message, signature, peer_key) do
      :ok
    else
      {:error, :bad_signature}
    end
  end
end
