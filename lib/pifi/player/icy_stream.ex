defmodule PiFi.Player.IcyStream do
  @moduledoc """
  Takes the ICY blocks out of a Shoutcast stream.

  A Shoutcast server that gets the `Icy-MetaData: 1` request header answers with
  an `icy-metaint` header, and it then puts a block of text into the audio after
  each `icy-metaint` bytes. The block starts with one byte that gives the length
  in units of 16 bytes, and a length of zero means that the server has nothing new
  to say. Most blocks are empty, because the title changes once for each track.

      <-- 16384 bytes of audio --><4><StreamTitle='Coldplay - Hymn';\\0\\0\\0>...

  A decoder cannot read those bytes, so this module removes them and gives the
  audio alone. It also returns the new title, and it returns it once only: a server
  repeats the same title in each block.

  The bytes arrive in chunks of any size, and a block can start in one chunk and
  end in the next one. This module therefore keeps the point that it reached.

  A station that sends no `icy-metaint` header needs `new(nil)`. Every byte is
  then audio, and the station gives no title.
  """

  defstruct [:metaint, :phase, :title]

  @typedoc """
  Where the reader is in the stream.

  `{:audio, count}` waits for `count` more bytes of audio. `:length` waits for the
  byte that gives the length of a block. `{:block, count, held}` waits for `count`
  more bytes of a block, and `held` is the part that arrived already.
  """
  @type phase ::
          :all_audio | {:audio, non_neg_integer()} | :length | {:block, pos_integer(), binary()}

  @type t :: %__MODULE__{
          metaint: pos_integer() | nil,
          phase: phase(),
          title: String.t() | nil
        }

  @doc """
  Start a reader.

  `metaint` comes from the `icy-metaint` response header. A `nil` metaint means
  that the station sends no blocks.
  """
  @spec new(pos_integer() | nil) :: t()
  def new(nil), do: %__MODULE__{metaint: nil, phase: :all_audio}

  def new(metaint) when is_integer(metaint) and metaint > 0 do
    %__MODULE__{metaint: metaint, phase: {:audio, metaint}}
  end

  @doc """
  Read one chunk.

  It returns the audio of that chunk, each new title in the order that the stream
  gave them, and the reader for the next chunk.
  """
  @spec split(t(), binary()) :: {binary(), [String.t()], t()}
  def split(%__MODULE__{} = icy, data), do: read(data, icy, <<>>, [])

  defp read(<<>>, icy, audio, titles), do: {audio, Enum.reverse(titles), icy}

  defp read(data, %__MODULE__{phase: :all_audio} = icy, audio, titles) do
    {audio <> data, Enum.reverse(titles), icy}
  end

  defp read(data, %__MODULE__{phase: {:audio, 0}} = icy, audio, titles) do
    read(data, %__MODULE__{icy | phase: :length}, audio, titles)
  end

  defp read(data, %__MODULE__{phase: {:audio, count}} = icy, audio, titles) do
    size = min(count, byte_size(data))
    <<taken::binary-size(^size), rest::binary>> = data

    read(rest, %__MODULE__{icy | phase: {:audio, count - size}}, audio <> taken, titles)
  end

  defp read(<<0, rest::binary>>, %__MODULE__{phase: :length} = icy, audio, titles) do
    read(rest, %__MODULE__{icy | phase: {:audio, icy.metaint}}, audio, titles)
  end

  defp read(<<length, rest::binary>>, %__MODULE__{phase: :length} = icy, audio, titles) do
    read(rest, %__MODULE__{icy | phase: {:block, length * 16, <<>>}}, audio, titles)
  end

  defp read(data, %__MODULE__{phase: {:block, count, held}} = icy, audio, titles) do
    size = min(count, byte_size(data))
    <<taken::binary-size(^size), rest::binary>> = data

    case count - size do
      0 ->
        {icy, titles} = take_title(icy, held <> taken, titles)
        read(rest, %__MODULE__{icy | phase: {:audio, icy.metaint}}, audio, titles)

      left ->
        read(rest, %__MODULE__{icy | phase: {:block, left, held <> taken}}, audio, titles)
    end
  end

  defp take_title(%__MODULE__{} = icy, block, titles) do
    case title(block) do
      nil -> {icy, titles}
      same when same == icy.title -> {icy, titles}
      title -> {%__MODULE__{icy | title: title}, [title | titles]}
    end
  end

  defp title(block) do
    case Regex.named_captures(~r/StreamTitle='(?<title>.*?)';/s, text(block)) do
      %{"title" => title} -> present(title)
      nil -> nil
    end
  end

  # A server is free to send any bytes here. Latin-1 is the common second choice
  # after UTF-8, and a page cannot hold a title that is neither.
  defp text(block) do
    if String.valid?(block) do
      block
    else
      case :unicode.characters_to_binary(block, :latin1, :utf8) do
        text when is_binary(text) -> text
        _other -> ""
      end
    end
  end

  defp present(title) do
    case String.trim(title) do
      "" -> nil
      title -> title
    end
  end
end
