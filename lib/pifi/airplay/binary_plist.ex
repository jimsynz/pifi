defmodule PiFi.AirPlay.BinaryPlist do
  @moduledoc """
  Reads the binary property lists that AirPlay speaks.

  **AirPlay carries its messages as binary plists**, in the body of requests that look
  like RTSP. There is no package for this on Hex, so a receiver has to read them itself.

  This is a spike. It is here rather than in a library of its own because it has not
  earned one yet: when there is enough of a receiver to extract, this goes with it. See
  the AirPlay 2 issue.

  ## The format

  Eight bytes of header, then the objects, then a table of where each object starts,
  then thirty-two bytes of trailer that say how to read the table. Nothing is where you
  would expect until the trailer is read, which is why this reads backwards.

  An object begins with a marker byte: the high nibble says what it is and the low
  nibble usually says how long. A low nibble of `0xF` means the length did not fit, and
  an integer object follows with the real one.

  **A container holds references and not values.** An array of three holds three indexes
  into the offset table, and a dictionary of three holds three key indexes followed by
  three value indexes. So a container is read by reading the table and then reading
  whatever the table points at, and a plist that pointed at itself would not end. See
  `@max_depth`.

  ## What it does not do

  Sets, UIDs and fill are in the format and AirPlay does not use them, so they are
  rejected rather than half-read. A value this cannot read is an error and never a
  guess, because a guess in a handshake is a session that fails later and further away.
  """

  # The offsets of a plist point forwards, so a cycle cannot happen in a file that
  # Apple wrote. One that somebody else wrote is a different matter, and a receiver
  # reads what the network hands it.
  @max_depth 32

  # Seconds between 1970-01-01 and 2001-01-01, which is where a plist counts from.
  @epoch_offset 978_307_200

  @header "bplist00"
  @trailer_size 32

  @typedoc "Anything a plist can hold that AirPlay uses."
  @type value ::
          nil
          | boolean()
          | integer()
          | float()
          | String.t()
          | binary()
          | DateTime.t()
          | [value()]
          | %{optional(String.t()) => value()}

  @doc """
  Read a binary plist.

      iex> {:ok, plist} = Base.decode64("YnBsaXN0MDDQCAAAAAAAAAEBAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAJ")
      iex> PiFi.AirPlay.BinaryPlist.decode(plist)
      {:ok, %{}}

  **Anything that is not a binary plist is an error and not a crash**, because this
  reads what arrives on a socket.

      iex> PiFi.AirPlay.BinaryPlist.decode("<?xml version=\\"1.0\\"?>")
      {:error, :not_a_binary_plist}
  """
  @spec decode(binary()) :: {:ok, value()} | {:error, term()}
  def decode(<<@header, _rest::binary>> = plist) when byte_size(plist) >= 8 + @trailer_size do
    size = byte_size(plist)
    trailer = binary_part(plist, size - @trailer_size, @trailer_size)

    <<_unused::binary-size(5), _sort_version, offset_size, reference_size, count::big-64,
      top::big-64, table_at::big-64>> = trailer

    with :ok <- sane?(size, offset_size, reference_size, count, top, table_at),
         {:ok, offsets} <- offsets(plist, table_at, offset_size, count) do
      read(plist, offsets, reference_size, top, 0)
    end
  end

  def decode(_plist), do: {:error, :not_a_binary_plist}

  @doc """
  Read a binary plist, or raise.

      iex> {:ok, plist} = Base.decode64("YnBsaXN0MDDQCAAAAAAAAAEBAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAJ")
      iex> PiFi.AirPlay.BinaryPlist.decode!(plist)
      %{}
  """
  @spec decode!(binary()) :: value()
  def decode!(plist) do
    case decode(plist) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, "not a binary plist: #{inspect(reason)}"
    end
  end

  # **A trailer names sizes, and a damaged one names impossible sizes.** Reading a table
  # of four thousand million entries out of a message of two hundred bytes is how a
  # parser turns a bad packet into an outage, so the numbers are checked against the
  # message before anything is read.
  defp sane?(size, offset_size, reference_size, count, top, table_at) do
    cond do
      offset_size < 1 or offset_size > 8 -> {:error, :bad_offset_size}
      reference_size < 1 or reference_size > 8 -> {:error, :bad_reference_size}
      top >= count -> {:error, :bad_top_object}
      table_at + count * offset_size > size -> {:error, :bad_offset_table}
      true -> :ok
    end
  end

  defp offsets(plist, table_at, offset_size, count) do
    table = binary_part(plist, table_at, count * offset_size)

    bits = offset_size * 8

    {:ok, for(<<offset::big-size(^bits) <- table>>, do: offset)}
  rescue
    ArgumentError -> {:error, :bad_offset_table}
  end

  defp read(_plist, _offsets, _reference_size, _index, depth) when depth > @max_depth do
    {:error, :too_deep}
  end

  defp read(plist, offsets, reference_size, index, depth) do
    case Enum.at(offsets, index) do
      nil -> {:error, :no_such_object}
      offset -> object(plist, offsets, reference_size, offset, depth)
    end
  end

  defp object(plist, offsets, reference_size, offset, depth) do
    case plist do
      <<_::binary-size(^offset), marker, rest::binary>> ->
        marked(marker, rest, plist, offsets, reference_size, depth)

      _short ->
        {:error, :truncated}
    end
  end

  defp marked(0x00, _rest, _plist, _offsets, _reference_size, _depth), do: {:ok, nil}
  defp marked(0x08, _rest, _plist, _offsets, _reference_size, _depth), do: {:ok, false}
  defp marked(0x09, _rest, _plist, _offsets, _reference_size, _depth), do: {:ok, true}

  # An integer is 2^n bytes. One of eight is signed and the shorter ones are not, which
  # is the format and not a choice.
  defp marked(marker, rest, _plist, _offsets, _reference_size, _depth)
       when marker in 0x10..0x13 do
    bytes = Bitwise.bsl(1, marker - 0x10)
    bits = bytes * 8

    case rest do
      <<value::big-signed-size(^bits), _::binary>> when bytes == 8 -> {:ok, value}
      <<value::big-size(^bits), _::binary>> -> {:ok, value}
      _short -> {:error, :truncated}
    end
  end

  defp marked(0x22, <<value::big-float-32, _::binary>>, _p, _o, _r, _d), do: {:ok, value}
  defp marked(0x23, <<value::big-float-64, _::binary>>, _p, _o, _r, _d), do: {:ok, value}

  # A date counts seconds from 2001, and it is a float because it can be fractional.
  defp marked(0x33, <<seconds::big-float-64, _::binary>>, _p, _o, _r, _d) do
    {:ok, DateTime.from_unix!(trunc(seconds) + @epoch_offset)}
  end

  defp marked(marker, rest, plist, offsets, reference_size, depth)
       when Bitwise.bsr(marker, 4) in [0x4, 0x5, 0x6, 0xA, 0xD] do
    with {:ok, count, rest} <- count(marker, rest) do
      sized(Bitwise.bsr(marker, 4), count, rest, plist, offsets, reference_size, depth)
    end
  end

  defp marked(marker, _rest, _plist, _offsets, _reference_size, _depth) do
    {:error, {:unsupported_marker, marker}}
  end

  # **A low nibble of `0xF` means the length did not fit in it**, and an integer object
  # follows with the real one.
  defp count(marker, rest), do: counted(Bitwise.band(marker, 0x0F), rest)

  defp counted(0x0F, rest), do: long_count(rest)
  defp counted(small, rest), do: {:ok, small, rest}

  defp long_count(<<next, more::binary>>) when next in 0x10..0x13 do
    bits = Bitwise.bsl(1, next - 0x10) * 8

    case more do
      <<count::big-size(^bits), rest::binary>> -> {:ok, count, rest}
      _short -> {:error, :truncated}
    end
  end

  defp long_count(_other), do: {:error, :bad_length}

  defp sized(0x4, count, rest, _plist, _offsets, _reference_size, _depth) do
    case rest do
      <<data::binary-size(^count), _::binary>> -> {:ok, data}
      _short -> {:error, :truncated}
    end
  end

  defp sized(0x5, count, rest, _plist, _offsets, _reference_size, _depth) do
    case rest do
      <<text::binary-size(^count), _::binary>> -> {:ok, text}
      _short -> {:error, :truncated}
    end
  end

  # **A UTF-16 string counts characters and not bytes**, so the length doubles.
  defp sized(0x6, count, rest, _plist, _offsets, _reference_size, _depth) do
    pairs = count * 2

    case rest do
      <<text::binary-size(^pairs), _::binary>> ->
        case :unicode.characters_to_binary(text, {:utf16, :big}, :utf8) do
          converted when is_binary(converted) -> {:ok, converted}
          _error -> {:error, :bad_utf16}
        end

      _short ->
        {:error, :truncated}
    end
  end

  defp sized(0xA, count, rest, plist, offsets, reference_size, depth) do
    with {:ok, references} <- references(rest, count, reference_size) do
      collect(references, plist, offsets, reference_size, depth)
    end
  end

  # **A dictionary is every key and then every value**, and not key and value in turns.
  defp sized(0xD, count, rest, plist, offsets, reference_size, depth) do
    with {:ok, references} <- references(rest, count * 2, reference_size),
         {keys, values} = Enum.split(references, count),
         {:ok, keys} <- collect(keys, plist, offsets, reference_size, depth),
         {:ok, values} <- collect(values, plist, offsets, reference_size, depth) do
      {:ok, Map.new(Enum.zip(keys, values))}
    end
  end

  defp references(rest, count, reference_size) do
    bytes = count * reference_size

    case rest do
      <<table::binary-size(^bytes), _::binary>> ->
        bits = reference_size * 8

        {:ok, for(<<reference::big-size(^bits) <- table>>, do: reference)}

      _short ->
        {:error, :truncated}
    end
  end

  defp collect(references, plist, offsets, reference_size, depth) do
    Enum.reduce_while(references, {:ok, []}, fn reference, {:ok, found} ->
      case read(plist, offsets, reference_size, reference, depth + 1) do
        {:ok, value} -> {:cont, {:ok, [value | found]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, found} -> {:ok, Enum.reverse(found)}
      {:error, reason} -> {:error, reason}
    end
  end
end
