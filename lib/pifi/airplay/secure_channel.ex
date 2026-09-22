defmodule PiFi.AirPlay.SecureChannel do
  @moduledoc """
  What the connection speaks once pairing is done.

  **Everything after the handshake is encrypted.** A telephone that has paired sends its
  next `SETUP` as ciphertext, so a receiver that stopped at pairing sees rubbish and
  closes the connection. This is the layer that stops happening.

  ## A message is a run of blocks, and each carries its own length

  Each block is two bytes of length, then that many bytes of ciphertext, then a sixteen
  byte tag. Plaintext longer than 1024 bytes is split across several blocks rather than
  sent as one, which is the format and not a choice — a receiver that expected one block
  per message would stop part way through a long `SETUP` plist.

  **The length is little-endian and it is also the associated data.** Both matter: it is
  the one field in AirPlay that is not big-endian, and a reader that authenticated the
  ciphertext alone would let somebody change how much of the stream got read.

  ## Two counters, and they never go backwards

  Each direction counts its own blocks, and the count is the nonce. They are not
  interchangeable and neither is reset: reusing a nonce with the same key is the one
  mistake ChaCha20-Poly1305 does not survive, so the counter belongs to the channel and
  is threaded through rather than kept anywhere it could be rolled back.

  ## Reading is incremental

  `open/2` takes whatever has arrived and gives back the blocks that are whole, with the
  rest handed back for next time. A block that is half here is not an error — it is a
  socket, and more is coming.
  """

  alias PiFi.AirPlay.Cipher
  alias PiFi.AirPlay.Hkdf

  @block_max 1024
  @tag_bytes 16
  @key_bytes 32

  @salt "Control-Salt"

  # **These names are the controller's, and this is the accessory, so they cross over.**
  # The controller writes with `Control-Write-Encryption-Key`, which is therefore what
  # this device reads with. Taking the names at face value gives a session where every
  # message after the handshake fails to authenticate and nothing says why.
  @controller_writes "Control-Write-Encryption-Key"
  @controller_reads "Control-Read-Encryption-Key"

  @typedoc "The keys and counters for one connection."
  @type t :: %__MODULE__{
          read_key: binary(),
          write_key: binary(),
          read_counter: non_neg_integer(),
          write_counter: non_neg_integer()
        }

  defstruct [:read_key, :write_key, read_counter: 0, write_counter: 0]

  @doc """
  A channel from the keys a pairing left behind.

  `read` is what arrives and `write` is what leaves, from this device's point of view.
  `PiFi.AirPlay.PairVerify.finish/3` answers with them the same way round.
  """
  @spec new(%{read: binary(), write: binary()}) :: t()
  def new(%{read: read, write: write}) do
    %__MODULE__{read_key: read, write_key: write}
  end

  @doc """
  The two control keys a shared secret gives, from this device's point of view.

  Both ways of pairing end with a secret and want the same two keys out of it: the
  Curve25519 secret of a Pair-Verify, and the SRP session key of a transient Pair-Setup.
  **They are derived in one place so the two cannot drift apart.**
  """
  @spec keys(binary()) :: %{read: binary(), write: binary()}
  def keys(shared) do
    %{
      read: Hkdf.derive(:sha512, shared, @salt, @controller_writes, @key_bytes),
      write: Hkdf.derive(:sha512, shared, @salt, @controller_reads, @key_bytes)
    }
  end

  @doc """
  A channel straight from a shared secret.
  """
  @spec from_secret(binary()) :: t()
  def from_secret(shared), do: shared |> keys() |> new()

  @doc """
  The largest plaintext one block carries.

      iex> PiFi.AirPlay.SecureChannel.block_max()
      1024
  """
  @spec block_max() :: pos_integer()
  def block_max, do: @block_max

  @doc """
  Encrypt something to send, and give back the channel with its counter moved on.
  """
  @spec seal(t(), binary()) :: {binary(), t()}
  def seal(%__MODULE__{} = channel, plaintext) do
    plaintext
    |> blocks()
    |> Enum.reduce({[], channel}, fn block, {written, channel} ->
      length = byte_size(block)
      aad = <<length::little-16>>

      sealed =
        Cipher.seal(channel.write_key, Cipher.counter_nonce(channel.write_counter), block, aad)

      {[written, aad, sealed], %{channel | write_counter: channel.write_counter + 1}}
    end)
    |> then(fn {written, channel} -> {IO.iodata_to_binary(written), channel} end)
  end

  @doc """
  Decrypt whatever whole blocks have arrived.

  Answers the plaintext, whatever bytes were left over, and the channel. **A tag that
  does not check is an error and never a skipped block**: the stream is a sequence and
  there is no finding the place again once one is lost.
  """
  @spec open(t(), binary()) :: {:ok, binary(), binary(), t()} | {:error, term()}
  def open(%__MODULE__{} = channel, buffer), do: open(channel, buffer, [])

  # **A block cannot be longer than 1024, so a length that says otherwise is not a block
  # this is part way through.** Without this, plaintext sent to an encrypted channel
  # reads as a length of some tens of thousands and the connection waits for bytes that
  # are never coming, holding whatever arrives meanwhile.
  defp open(_channel, <<length::little-16, _rest::binary>>, _found) when length > @block_max do
    {:error, {:block_too_long, length}}
  end

  defp open(channel, <<length::little-16, rest::binary>> = buffer, found)
       when byte_size(rest) >= length + @tag_bytes do
    sealed_size = length + @tag_bytes
    <<_head::binary-size(2), sealed::binary-size(^sealed_size), remainder::binary>> = buffer

    case Cipher.open(
           channel.read_key,
           Cipher.counter_nonce(channel.read_counter),
           sealed,
           <<length::little-16>>
         ) do
      {:ok, plain} ->
        open(%{channel | read_counter: channel.read_counter + 1}, remainder, [found, plain])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open(channel, rest, found), do: {:ok, IO.iodata_to_binary(found), rest, channel}

  # A message longer than a block goes in several, and nothing about the split is
  # visible to whatever reads the other end.
  defp blocks(<<>>), do: []

  defp blocks(plaintext) when byte_size(plaintext) <= @block_max, do: [plaintext]

  defp blocks(<<block::binary-size(@block_max), rest::binary>>), do: [block | blocks(rest)]
end
