defmodule PiFi.AirPlay.Tlv8 do
  @moduledoc """
  Reads and writes the TLV8 encoding that AirPlay pairing speaks.

  **Pair-Setup and Pair-Verify carry their arguments as TLV8** rather than as plists.
  It is the simplest encoding in the protocol: a byte that says what, a byte that says
  how long, and that many bytes.

  This is a spike, and it lives here for the same reason `PiFi.AirPlay.BinaryPlist`
  does.

  ## A value longer than 255 is split, and the pieces are not separate values

  A length is one byte, so a public key of 384 bytes cannot be one item. It is written
  as consecutive items of the same type, each up to 255 bytes, and a reader joins them.
  **Only consecutive ones join.** Two items of the same type with something between them
  are two values, which is how a message carries more than one certificate.

  A zero-length item of type `0xFF` is the separator that pairing uses to say "that was
  one value, the next is another of the same kind".

  ## It keeps the order

  A map would lose it, and pairing has messages where the same type appears twice with
  a separator between. So this reads to a list of pairs and writes from one, and
  `fetch/2` is there for the common case of wanting one value by type.
  """

  @separator 0xFF
  @max_fragment 255

  @typedoc "One item: what it is, and its bytes."
  @type item :: {0..255, binary()}

  @doc """
  The type that separates two values of the same kind.

      iex> PiFi.AirPlay.Tlv8.separator()
      0xFF
  """
  @spec separator() :: 0..255
  def separator, do: @separator

  @doc """
  Read a TLV8 message.

  Consecutive items of one type join into one value, and the order is kept.

      iex> PiFi.AirPlay.Tlv8.decode(<<0x06, 0x01, 0x01, 0x01, 0x03, "abc">>)
      {:ok, [{0x06, <<0x01>>}, {0x01, "abc"}]}

  **A message that runs out mid-item is an error**, because this reads what arrives on
  a socket.

      iex> PiFi.AirPlay.Tlv8.decode(<<0x06, 0x04, 0x01>>)
      {:error, :truncated}
  """
  @spec decode(binary()) :: {:ok, [item()]} | {:error, term()}
  def decode(bytes), do: decode(bytes, [])

  defp decode(<<>>, found), do: {:ok, found |> Enum.reverse() |> join()}

  defp decode(<<type, length, value::binary-size(length), rest::binary>>, found) do
    decode(rest, [{type, value} | found])
  end

  defp decode(_short, _found), do: {:error, :truncated}

  @doc """
  Read a TLV8 message, or raise.
  """
  @spec decode!(binary()) :: [item()]
  def decode!(bytes) do
    case decode(bytes) do
      {:ok, items} -> items
      {:error, reason} -> raise ArgumentError, "not a TLV8 message: #{inspect(reason)}"
    end
  end

  @doc """
  Write a TLV8 message.

  A value longer than 255 bytes is split across consecutive items of its own type, and
  a reader joins them again.

      iex> PiFi.AirPlay.Tlv8.encode([{0x06, <<0x01>>}, {0x01, "abc"}])
      <<0x06, 0x01, 0x01, 0x01, 0x03, "abc">>

      iex> long = String.duplicate("x", 300)
      iex> encoded = PiFi.AirPlay.Tlv8.encode([{0x03, long}])
      iex> PiFi.AirPlay.Tlv8.decode(encoded)
      {:ok, [{0x03, String.duplicate("x", 300)}]}
  """
  @spec encode([item()]) :: binary()
  def encode(items) do
    items
    |> Enum.map(fn {type, value} -> fragments(type, value) end)
    |> IO.iodata_to_binary()
  end

  @doc """
  The first value of one type.

      iex> PiFi.AirPlay.Tlv8.fetch([{0x06, <<0x01>>}, {0x01, "abc"}], 0x01)
      {:ok, "abc"}

      iex> PiFi.AirPlay.Tlv8.fetch([{0x06, <<0x01>>}], 0x01)
      :error
  """
  @spec fetch([item()], 0..255) :: {:ok, binary()} | :error
  def fetch(items, type) do
    case List.keyfind(items, type, 0) do
      {^type, value} -> {:ok, value}
      nil -> :error
    end
  end

  # **A value of exactly 255 needs a trailing empty fragment**, or a reader cannot tell
  # it from a value that was split and whose second half is still coming. Apple's own
  # writer emits one, and a reader that joins consecutive items handles either.
  defp fragments(type, value) when byte_size(value) <= @max_fragment do
    [<<type, byte_size(value)>>, value]
  end

  defp fragments(type, value) do
    <<head::binary-size(@max_fragment), rest::binary>> = value

    [<<type, @max_fragment>>, head | List.wrap(fragments(type, rest))]
  end

  # **Only consecutive items of one type are one value.** Two of a type with something
  # between them are two values, which is how a message carries more than one of a kind.
  defp join([]), do: []

  defp join([{type, value} | rest]) do
    {same, other} = Enum.split_while(rest, &match?({^type, _value}, &1))

    joined = Enum.reduce(same, value, fn {_type, more}, acc -> acc <> more end)

    [{type, joined} | join(other)]
  end
end
