defmodule PiFi.AirPlay.Cipher do
  @moduledoc """
  The ChaCha20-Poly1305 framing that AirPlay pairing and its sessions use.

  `:crypto` has the algorithm. What is here is the two ways AirPlay builds a nonce for
  it, which is where an implementation goes wrong quietly.

  ## Two nonces, and they are built differently

  **A pairing message names its nonce.** Each step of Pair-Setup and Pair-Verify uses a
  fixed label — `PS-Msg05`, `PV-Msg02` and so on — padded on the **left** with zeros to
  twelve bytes. Padding on the right gives a nonce that is wrong for every message and
  an authentication failure with nothing to point at.

  **A session counts.** Once paired, each message uses four zero bytes and then an
  eight-byte counter, **little-endian**, which is the one place in a protocol otherwise
  full of big-endian numbers where the order flips. The counter starts at zero and each
  direction counts separately.

  ## The tag travels with the ciphertext

  `:crypto` returns them apart and AirPlay sends them joined, tag last. `seal/4` joins
  them and `open/4` splits them, so nothing above this has to remember which way round
  they go.

  ## A bad tag is an answer and not an exception

  Every byte here arrived over a network. A wrong tag means the message was damaged or
  forged, and either way the answer is to say so and drop it.
  """

  @tag_bytes 16
  @nonce_bytes 12

  @typedoc "A key, which is always 32 bytes for this algorithm."
  @type key :: <<_::256>>

  @doc """
  The nonce for a named pairing message.

  The label is padded on the left, which is the half that is easy to get backwards.

      iex> PiFi.AirPlay.Cipher.message_nonce("PS-Msg05")
      <<0, 0, 0, 0, "PS-Msg05">>

      iex> byte_size(PiFi.AirPlay.Cipher.message_nonce("PV-Msg02"))
      12
  """
  @spec message_nonce(binary()) :: <<_::96>>
  def message_nonce(label) when byte_size(label) <= @nonce_bytes do
    :binary.copy(<<0>>, @nonce_bytes - byte_size(label)) <> label
  end

  @doc """
  The nonce for the nth message of a session.

  **The counter is little-endian**, which is the one place the byte order flips.

      iex> PiFi.AirPlay.Cipher.counter_nonce(0)
      <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>

      iex> PiFi.AirPlay.Cipher.counter_nonce(1)
      <<0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0>>

      iex> PiFi.AirPlay.Cipher.counter_nonce(258)
      <<0, 0, 0, 0, 2, 1, 0, 0, 0, 0, 0, 0>>
  """
  @spec counter_nonce(non_neg_integer()) :: <<_::96>>
  def counter_nonce(counter) when counter >= 0 do
    <<0::32, counter::little-64>>
  end

  @doc """
  Encrypt, and put the tag on the end where AirPlay expects it.
  """
  @spec seal(key(), binary(), binary(), binary()) :: binary()
  def seal(key, nonce, plaintext, aad \\ <<>>) do
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:chacha20_poly1305, key, nonce, plaintext, aad, true)

    ciphertext <> tag
  end

  @doc """
  Split the tag off the end, decrypt, and check it.

  **A wrong tag is `{:error, :bad_tag}`.** Every byte of this arrived over a network, so
  a message that does not authenticate is one to drop rather than one to raise about.
  """
  @spec open(key(), binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, :bad_tag | :too_short}
  def open(key, nonce, sealed, aad \\ <<>>) do
    if byte_size(sealed) < @tag_bytes do
      {:error, :too_short}
    else
      body = byte_size(sealed) - @tag_bytes

      <<ciphertext::binary-size(^body), tag::binary-size(@tag_bytes)>> = sealed

      decrypted(key, nonce, ciphertext, tag, aad)
    end
  end

  @doc """
  How many bytes the tag takes.

      iex> PiFi.AirPlay.Cipher.tag_bytes()
      16
  """
  @spec tag_bytes() :: pos_integer()
  def tag_bytes, do: @tag_bytes

  defp decrypted(key, nonce, ciphertext, tag, aad) do
    case :crypto.crypto_one_time_aead(:chacha20_poly1305, key, nonce, ciphertext, aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :bad_tag}
    end
  end
end
