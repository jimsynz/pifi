defmodule MyHiFi.Player.Mp3Frame do
  @moduledoc """
  Finds the boundary of an MP3 frame a little before a byte of a file.

  A resume needs this for two reasons.

  **The middle of a frame is not a place where audio begins.** MAD skips bytes
  until it finds the next frame, one byte at a time. A read on the board on
  2026-08-24 measured 591 such skips after a resume, which is under two frames and
  about 50 ms.

  **The byte that a resume holds is in front of what a person heard.**
  `MyHiFi.Player.FileSource` reports the byte that it read, and the pipeline holds a
  lead of one to four seconds over the sound. Opening the file at that byte steps
  over a second or two of speech. A person who resumes must hear a little again, and
  never lose a word, so this steps back before it aligns.

  ## Why it walks forward

  An MP3 frame holds no pointer to the frame before it, so the only way back is to
  look for the 11 bits of a sync word. **Those bits appear inside audio as well**,
  and a scan backwards would often stop on one of them. That is the same trap that
  MAD meets when it skips a byte at a time.

  This reads a window that ends at the byte, finds a frame inside it, and walks
  forward. A walk forward confirms itself: the length that a header gives lands
  exactly on the next sync word, so two frames in a row name a real one. The window
  is about 10 KB and it parses a few hundred headers, so this needs no walk of the
  whole file.
  """

  import Bitwise

  # Layer III of each version, in kilobits each second.
  @mpeg1 {nil, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, nil}
  @mpeg2 {nil, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, nil}

  @rates_v1 {44_100, 48_000, 32_000}
  @rates_v2 {22_050, 24_000, 16_000}
  @rates_v25 {11_025, 12_000, 8_000}

  # 320 kbit/s at 32 kHz with a padding byte is the largest frame that Layer III
  # allows, and a window needs that much room after the target to confirm a frame
  # that ends past it.
  @max_frame_bytes 1441

  # How far before the target to look for a frame. One frame of any bitrate fits in
  # this many times over, so a window that holds no frame at all holds no audio.
  @search_bytes 8192

  @doc """
  The last frame boundary at or before `byte` less `margin`.

  `margin` is in bytes and not in milliseconds, because the lead that this steps
  back over is itself a count of bytes: the reader read that many more than a person
  heard. A count of bytes therefore needs no bitrate, and it holds for a variable
  bitrate file as well as a constant one.

  It gives 0 when the margin reaches the start of the file. The first byte of a file
  is where a first play begins, and `Membrane.MP3.MAD.Decoder` steps over an ID3 tag
  itself.
  """
  @spec boundary_before(:file.fd(), non_neg_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def boundary_before(_device, byte, margin) when byte - margin <= 0, do: {:ok, 0}

  def boundary_before(device, byte, margin) do
    target = byte - margin
    from = max(target - @search_bytes, 0)

    case :file.pread(device, from, target - from + @max_frame_bytes) do
      {:ok, window} -> boundary(window, from, target - from)
      :eof -> {:error, :no_frame}
      {:error, reason} -> {:error, reason}
    end
  end

  defp boundary(window, from, limit) do
    case first_frame(window, 0) do
      nil -> {:error, :no_frame}
      index -> {:ok, from + walk(window, index, limit)}
    end
  end

  # A frame that a header names, and a second one where its length says. Audio holds
  # the bits of a sync word often, and it holds two that agree on a length rarely.
  defp first_frame(window, index) do
    cond do
      index + @max_frame_bytes >= byte_size(window) ->
        nil

      confirmed?(window, index) ->
        index

      true ->
        first_frame(window, index + 1)
    end
  end

  defp confirmed?(window, index) do
    with {:ok, length} <- length_at(window, index),
         {:ok, _next} <- length_at(window, index + length) do
      true
    else
      _other -> false
    end
  end

  # The last boundary that is not past the target. Each step is one frame, so this
  # cannot land inside one.
  defp walk(window, index, limit) do
    case length_at(window, index) do
      {:ok, length} when index + length <= limit -> walk(window, index + length, limit)
      _other -> index
    end
  end

  defp length_at(window, index) when index + 4 <= byte_size(window) do
    window |> binary_part(index, 4) |> header()
  end

  defp length_at(_window, _index), do: :error

  defp header(<<0xFF, second, third, _fourth>>) when (second &&& 0xE0) == 0xE0 do
    version = second >>> 3 &&& 0x03
    layer = second >>> 1 &&& 0x03
    index = third >>> 4 &&& 0x0F
    rate_index = third >>> 2 &&& 0x03
    padding = third >>> 1 &&& 0x01

    with true <- layer == 0x01,
         {:ok, kilobits} <- lookup(table(version), index),
         {:ok, rate} <- rate(version, rate_index) do
      {:ok, div(div(samples(version), 8) * kilobits * 1000, rate) + padding}
    else
      _other -> :error
    end
  end

  defp header(_other), do: :error

  defp samples(0x03), do: 1152
  defp samples(_version), do: 576

  defp table(0x03), do: @mpeg1
  defp table(0x02), do: @mpeg2
  defp table(0x00), do: @mpeg2
  defp table(_reserved), do: nil

  defp rate(_version, 0x03), do: :error
  defp rate(0x03, index), do: {:ok, elem(@rates_v1, index)}
  defp rate(0x02, index), do: {:ok, elem(@rates_v2, index)}
  defp rate(0x00, index), do: {:ok, elem(@rates_v25, index)}
  defp rate(_reserved, _index), do: :error

  defp lookup(nil, _index), do: :error

  defp lookup(table, index) do
    case elem(table, index) do
      nil -> :error
      kilobits -> {:ok, kilobits}
    end
  end
end
