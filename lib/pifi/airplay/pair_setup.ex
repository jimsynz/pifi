defmodule PiFi.AirPlay.PairSetup do
  @moduledoc """
  The exchange that happens the first time a telephone meets this device.

  It is SRP: both sides know a short code, and they end up holding the same long key
  without the code ever crossing the network. Six messages, and this device answers
  three of them.

  - **M1** the telephone says it wants to pair. `start/2` answers **M2** with the salt
    and the accessory's SRP public value.
  - **M3** the telephone sends its own public value and a proof that it knew the code.
    `prove/2` checks it and answers **M4** with a proof of its own.
  - **M5** the telephone sends its long-term identity, encrypted. `finish/3` checks the
    signature and answers **M6** with this device's.

  ## Transient pairing stops at M4, and that is the usual case

  An iPhone sending audio does not want a permanent pairing, so it sets the transient
  flag in M1 and **the exchange is finished when M4 is sent**. The SRP session key
  becomes the key for the connection and no long-term identity is exchanged in either
  direction. There is nothing to remember and nothing for
  `PiFi.AirPlay.PairVerify` to check later, because there will be no later.

  A telephone that does not set the flag is setting this device up as a HomeKit
  accessory. That one goes all the way to M6 and leaves a `PiFi.AirPlay.Pairing` behind.

  **The code for a transient pairing is `3939` and it is not a secret.** It is fixed and
  every implementation uses it, because a person casting audio is not asked to type
  anything. Treating it as though it protected something would be a mistake: what
  protects a transient pairing is being on the network, the same as AirPlay 1.

  ## The proof is compared in constant time

  A wrong proof is a wrong code, and a comparison that stopped at the first differing
  byte would say how much of a guess was right.

  ## What it does not decide

  `finish/3` takes a function to remember the telephone, in the way
  `PiFi.AirPlay.PairVerify` takes one to look it up. Whether a pairing is written down
  is a question about what a person has set up, not about the protocol.
  """

  alias PiFi.AirPlay.Cipher
  alias PiFi.AirPlay.Hkdf
  alias PiFi.AirPlay.Identity
  alias PiFi.AirPlay.Srp
  alias PiFi.AirPlay.Tlv8

  # The HomeKit TLV types this exchange uses. 19 is not in Apple's published list; it
  # arrived with AirPlay 2 and it is what carries the transient flag.
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

  @method_pair_setup <<0x00>>
  @flag_transient 0x10

  @error_authentication <<0x02>>

  @transient_code "3939"
  @salt_bytes 16
  @key_bytes 32
  @hash :sha512

  @encrypt_salt "Pair-Setup-Encrypt-Salt"
  @encrypt_info "Pair-Setup-Encrypt-Info"
  @controller_salt "Pair-Setup-Controller-Sign-Salt"
  @controller_info "Pair-Setup-Controller-Sign-Info"
  @accessory_salt "Pair-Setup-Accessory-Sign-Salt"
  @accessory_info "Pair-Setup-Accessory-Sign-Info"

  @message5_nonce "PS-Msg05"
  @message6_nonce "PS-Msg06"

  defmodule Exchange do
    @moduledoc "What the accessory has to remember between one message and the next."

    @type t :: %__MODULE__{
            identifier: binary(),
            salt: binary(),
            verifier: pos_integer(),
            private: pos_integer(),
            public: pos_integer(),
            transient?: boolean(),
            session_key: binary() | nil
          }

    defstruct [
      :identifier,
      :salt,
      :verifier,
      :private,
      :public,
      :session_key,
      transient?: false
    ]
  end

  @doc """
  Answer M1 with M2.

  The answer carries a fresh salt and this device's SRP public value. `transient?` on
  the exchange says whether the telephone asked for a pairing that is not written down.

  `identifier` is what this device calls itself, and it is the same one
  `PiFi.AirPlay.PairVerify` uses — a telephone that paired with one name and verified
  against another gets a signature it rejects.
  """
  @spec start(binary(), binary(), String.t()) ::
          {:ok, binary(), Exchange.t()} | {:error, term()}
  def start(identifier, request, code \\ @transient_code) do
    with {:ok, items} <- Tlv8.decode(request),
         :ok <- expect_method(items) do
      group = Srp.group_3072()
      salt = :crypto.strong_rand_bytes(@salt_bytes)
      verifier = Srp.verifier(group, @hash, Srp.username(), code, salt)
      private = Srp.private_key()
      public = Srp.public_key(group, @hash, verifier, private)

      exchange = %Exchange{
        identifier: identifier,
        salt: salt,
        verifier: verifier,
        private: private,
        public: public,
        transient?: transient?(items)
      }

      answer =
        Tlv8.encode([
          {@state, <<0x02>>},
          {@public_key, Srp.bytes(group, public)},
          {@salt, salt}
        ])

      {:ok, answer, exchange}
    end
  end

  @doc """
  Answer M3 with M4, having checked that the telephone knew the code.

  **A transient exchange is finished here.** The third element says so, and it carries
  the key the connection uses. A pairing that is not transient goes on to `finish/3`.
  """
  @spec prove(Exchange.t(), binary()) ::
          {:ok, binary(), Exchange.t()} | {:done, binary(), binary()} | {:error, term()}
  def prove(%Exchange{} = exchange, request) do
    group = Srp.group_3072()

    with {:ok, items} <- Tlv8.decode(request),
         {:ok, client_public} <- fetch(items, @public_key),
         {:ok, client_proof} <- fetch(items, @proof),
         client = Srp.value(client_public),
         {:ok, secret} <-
           Srp.secret(group, @hash, client, exchange.public, exchange.verifier, exchange.private) do
      session_key = Srp.session_key(@hash, secret)

      expected =
        Srp.client_proof(
          group,
          @hash,
          Srp.username(),
          exchange.salt,
          client,
          exchange.public,
          session_key
        )

      if :crypto.hash_equals(expected, client_proof) do
        proven(
          exchange,
          session_key,
          Srp.server_proof(group, client, client_proof, session_key, @hash)
        )
      else
        {:error, :bad_proof}
      end
    end
  end

  # **A transient exchange has nothing left to do.** The key goes back to the caller
  # rather than staying on an exchange that will never be used again.
  defp proven(%Exchange{transient?: true}, session_key, proof) do
    {:done, m4(proof), session_key}
  end

  defp proven(%Exchange{} = exchange, session_key, proof) do
    {:ok, m4(proof), %{exchange | session_key: session_key}}
  end

  defp m4(proof), do: Tlv8.encode([{@state, <<0x04>>}, {@proof, proof}])

  @doc """
  Answer M5 with M6, and remember the telephone.

  `remember` is called with the identifier and the long-term public key the telephone
  sent. It answers `:ok`, or an error that stops the pairing.
  """
  @spec finish(Exchange.t(), binary(), (String.t(), binary() -> :ok | {:error, term()}), Path.t()) ::
          {:ok, binary()} | {:error, term()}
  def finish(
        %Exchange{session_key: session_key} = exchange,
        request,
        remember,
        data_dir \\ "/root"
      )
      when is_binary(session_key) do
    key = Hkdf.derive(@hash, session_key, @encrypt_salt, @encrypt_info, @key_bytes)

    with {:ok, items} <- Tlv8.decode(request),
         {:ok, sealed} <- fetch(items, @encrypted_data),
         {:ok, opened} <- Cipher.open(key, Cipher.message_nonce(@message5_nonce), sealed),
         {:ok, inner} <- Tlv8.decode(opened),
         {:ok, identifier} <- fetch(inner, @identifier),
         {:ok, peer_key} <- fetch(inner, @public_key),
         {:ok, peer_signature} <- fetch(inner, @signature),
         :ok <- check_signature(exchange, identifier, peer_key, peer_signature),
         :ok <- remember.(identifier, peer_key) do
      {:ok, answer(exchange, key, data_dir)}
    end
  end

  @doc """
  What to send when the exchange cannot go on.

  A telephone that gets this stops and tells the person, which is better than a
  connection that hangs.

      iex> PiFi.AirPlay.PairSetup.refusal(4) |> PiFi.AirPlay.Tlv8.decode!()
      [{0x06, <<4>>}, {0x07, <<2>>}]
  """
  @spec refusal(pos_integer(), binary()) :: binary()
  def refusal(state, error \\ @error_authentication) do
    Tlv8.encode([{@state, <<state>>}, {@error, error}])
  end

  @doc """
  The code a transient pairing uses.

      iex> PiFi.AirPlay.PairSetup.transient_code()
      "3939"
  """
  @spec transient_code() :: String.t()
  def transient_code, do: @transient_code

  defp answer(%Exchange{identifier: identifier, session_key: session_key}, key, data_dir) do
    public = Identity.public_key(data_dir)
    info = Hkdf.derive(@hash, session_key, @accessory_salt, @accessory_info, @key_bytes)
    signature = Identity.sign(info <> identifier <> public, data_dir)

    inner =
      Tlv8.encode([
        {@identifier, identifier},
        {@public_key, public},
        {@signature, signature}
      ])

    sealed = Cipher.seal(key, Cipher.message_nonce(@message6_nonce), inner)

    Tlv8.encode([{@state, <<0x06>>}, {@encrypted_data, sealed}])
  end

  # **The signature covers a derived value, the identifier and the key, in that order.**
  # Getting the order wrong gives a refusal with nothing to say why.
  defp check_signature(%Exchange{session_key: session_key}, identifier, peer_key, signature) do
    info = Hkdf.derive(@hash, session_key, @controller_salt, @controller_info, @key_bytes)

    if Identity.verify(info <> identifier <> peer_key, signature, peer_key) do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  defp expect_method(items) do
    case Tlv8.fetch(items, @method) do
      {:ok, @method_pair_setup} -> :ok
      {:ok, other} -> {:error, {:unsupported_method, other}}
      :error -> {:error, :no_method}
    end
  end

  defp transient?(items) do
    case Tlv8.fetch(items, @flags) do
      {:ok, <<@flag_transient>>} -> true
      _other -> false
    end
  end

  defp fetch(items, type) do
    case Tlv8.fetch(items, type) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing, type}}
    end
  end
end
