defmodule PiFi.Player.FlacFrame do
  @moduledoc """
  Reads the frames of a FLAC file, to find a place inside it.

  FLAC answers the same two questions that `PiFi.Player.Mp3Frame` answers, and it
  answers them in another way, because a FLAC frame is a different shape.

  ## A FLAC header names the time, and not the length

  An MP3 header and an ADTS header both name the length of their own frame, so a walk
  forward adds lengths and sums the time. **A FLAC header names neither length nor
  bitrate.** It names the number of the frame, or the number of the first sample of
  it, and the size of the block. A reader therefore knows exactly where it is in the
  audio and nothing about where the next frame begins.

  That turns the question around. A walk is impossible and unnecessary:
  `place/4` chooses a byte, reads the header there, and compares the sample number
  with the one that it wants. A measurement of a span is never needed, because each
  header carries its own place in the audio, so **the time that this reports is exact
  and not measured**.

  `seek/4` therefore bisects the file. About 20 probes reach any frame of a track of
  an hour, and each probe reads one window and parses a few headers.

  ## The CRC of the header is what makes a frame real

  **A skip that lands one byte inside a frame plays nothing at all.** A measurement on
  the host on 2026-09-11 fed `flac --decode --stdout --silent -` a stream that began
  one byte past a boundary: the program answered
  `FLAC__STREAM_DECODER_ERROR_STATUS_LOST_SYNC after processing 0 samples` and wrote
  no audio. The same stream from the boundary itself decoded every sample.

  A sync word alone cannot be trusted for that. The other two readers confirm a frame
  with the frame that follows it, and this one cannot, because it does not know where
  that frame begins. **A FLAC header carries a CRC-8 of itself instead**, and that is
  what this checks. A sweep of every byte of a 379 KB file on 2026-09-11 found all 288
  real frames and no false one.

  ## What the decoder needs, and what it does not

  **A skip needs no restart of the decoder.** The same measurement spliced the frames
  of one place on to the audio of another and gave the whole of the rest of the track,
  forward and backward, from the program that was already running. Each FLAC frame
  carries its own rate, channel count and sample size, so the program needs neither
  the `fLaC` marker nor the metadata again.

  A backward skip makes the program say that the sample number does not increase. It
  writes that to its standard error, which this firmware does not read, and it decodes
  every frame.
  """

  import Bitwise

  # The CRC-8 of a FLAC header, with the polynomial x^8 + x^2 + x^1 + x^0. A table of
  # 256 entries costs a few kilobytes and it saves 8 shifts for each byte, and a scan
  # of one window checks a few hundred candidates.
  @crc_table (for byte <- 0..255 do
                Enum.reduce(1..8, byte, fn _step, crc ->
                  if (crc &&& 0x80) == 0,
                    do: crc <<< 1 &&& 0xFF,
                    else: bxor(crc <<< 1, 0x07) &&& 0xFF
                end)
              end)
             |> List.to_tuple()

  # The block size that each code names. Code 0 is reserved, 6 and 7 name a count that
  # comes after the header, and this map holds the rest.
  @blocks %{
    1 => 192,
    2 => 576,
    3 => 1152,
    4 => 2304,
    5 => 4608,
    8 => 256,
    9 => 512,
    10 => 1024,
    11 => 2048,
    12 => 4096,
    13 => 8192,
    14 => 16_384,
    15 => 32_768
  }

  # The sample rate that each code names. Code 0 says that the rate is in the
  # STREAMINFO block, 12 to 14 name a rate that comes after the header, and 15 is
  # invalid.
  @rates %{
    1 => 88_200,
    2 => 176_400,
    3 => 192_000,
    4 => 8_000,
    5 => 16_000,
    6 => 22_050,
    7 => 24_000,
    8 => 32_000,
    9 => 44_100,
    10 => 48_000,
    11 => 96_000
  }

  # The two bytes that a header can begin with. The sync word takes 14 bits and the
  # bit after it is reserved at 0, so the second byte is one of these two and the bit
  # that differs is the blocking strategy. `:binary.matches/2` finds them in one call
  # of the runtime, which is what keeps a scan of a window away from the byte loop of
  # a walk.
  @syncs [<<0xFF, 0xF8>>, <<0xFF, 0xF9>>]

  # The longest header. The sync and the flags take 4 bytes, the coded number takes 7,
  # the block size takes 2, the rate takes 2, and the CRC takes 1.
  @max_header_bytes 16

  # How much of the file one probe reads while it looks for a frame. STREAMINFO names
  # the longest frame of the file, and this is what a probe reads when it names none.
  @scan_bytes 128 * 1024

  # A bisection of a file of 4 GB needs 32 probes, and this stops a file that gives an
  # answer that never narrows.
  @max_probes 40

  # Where a bisection stops and a walk finishes the work. Each step of the walk reads
  # one window, so a narrow range costs fewer reads than another probe.
  @narrow 64 * 1024

  # How many frames the walk at the end of a bisection steps over.
  @max_steps 64

  @typedoc "What STREAMINFO says about the file, and where the audio begins."
  @type info :: %{
          rate: pos_integer(),
          block: pos_integer(),
          channels: pos_integer(),
          samples: non_neg_integer(),
          max_frame: non_neg_integer(),
          audio_start: non_neg_integer()
        }

  @typedoc "One frame of the file."
  @type frame :: %{byte: non_neg_integer(), sample: non_neg_integer(), rate: pos_integer()}

  @doc """
  The byte to read next, and the time that the skip moves.

  `from` is the byte that the reader is at now, and `limit` is the count of bytes that
  the file has. `ms` is signed, and the `ms` of the answer carries the same sign.

  **The time is exact.** It is the difference between the sample number of the frame
  that the reader is at and the sample number of the frame that this chose, so it
  needs no measurement and it holds no error.
  """
  @spec place(:file.fd(), non_neg_integer(), integer(), non_neg_integer()) ::
          {:ok, %{byte: non_neg_integer(), ms: integer()}} | {:error, term()}
  def place(_device, from, 0, _limit), do: {:ok, %{byte: from, ms: 0}}

  def place(device, from, ms, limit) do
    with {:ok, info} <- stream_info(device),
         {:ok, here} <- frame_at(device, from, limit, info),
         {:ok, there} <- seek(device, wanted(here, ms, info), info, limit) do
      {:ok, %{byte: there.byte, ms: div((there.sample - here.sample) * 1000, here.rate)}}
    end
  end

  @doc """
  The first frame boundary at or before `byte` less `margin`.

  A resume opens the file at this byte, and a byte inside a frame gives the decoder
  no audio at all. See the module documentation for the measurement.

  It gives the first frame of the audio when the margin reaches the start, and not
  byte 0. **A resume needs no `fLaC` marker and no metadata**: each frame carries its
  own rate and width, and a stream of frames alone decoded every sample in the
  measurement of 2026-09-11.
  """
  @spec boundary_before(:file.fd(), non_neg_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def boundary_before(device, byte, margin) do
    with {:ok, info} <- stream_info(device),
         target = max(byte - margin, info.audio_start),
         {:ok, frame} <- frame_at(device, target, byte + @max_header_bytes, info) do
      {:ok, frame.byte}
    end
  end

  @doc """
  The shortest stream header that a decoder needs, for a stream that begins in the
  middle of the audio.

  **A decoder that reads no STREAMINFO does not know the shape of a sample.** `flac`
  writes a WAV header before it decodes a frame, so a stream of frames alone gave a
  header of `channels: 0` and `bits: 0`, and `PiFi.Player.PortDecoder` read that
  and stopped. A measurement on the host on 2026-09-11 showed both: the frames alone
  gave `RIFF` with zeros, and these 42 bytes in front of the same frames gave
  `channels: 2`, `bits: 16` and every remaining sample.

  It is the `fLaC` marker and the STREAMINFO block of the file, with the flag that
  says that no other metadata block follows. **The album art of a track does not come
  with it**: the metadata of one real track is 230 KB, and a decoder needs none of it.
  """
  @spec header(:file.fd()) :: {:ok, binary()} | {:error, term()}
  def header(device) do
    case :file.pread(device, 0, 4 + 4 + 34) do
      {:ok, <<"fLaC", _last::1, 0::7, 34::24, streaminfo::binary-size(34)>>} ->
        {:ok, "fLaC" <> <<1::1, 0::7, 34::24>> <> streaminfo}

      {:ok, _other} ->
        {:error, :not_flac}

      _other ->
        {:error, :not_flac}
    end
  end

  @doc """
  What the STREAMINFO block of the file says, and where the audio begins.

  The metadata blocks come between the `fLaC` marker and the first frame, and each one
  names its own length, so this reads the chain and stops at the block that says that
  it is the last.
  """
  @spec stream_info(:file.fd()) :: {:ok, info()} | {:error, term()}
  def stream_info(device) do
    case :file.pread(device, 0, 4) do
      {:ok, "fLaC"} -> blocks(device, 4, nil)
      {:ok, _other} -> {:error, :not_flac}
      :eof -> {:error, :not_flac}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The first frame at or after `byte`, and where it begins in the audio.

  A window with no frame gives `{:error, :no_frame}`.
  """
  @spec frame_at(:file.fd(), non_neg_integer(), non_neg_integer(), info()) ::
          {:ok, frame()} | {:error, term()}
  def frame_at(device, byte, limit, info) do
    from = max(byte, info.audio_start)
    width = min(scan_width(info), limit - from)

    if width < @max_header_bytes do
      {:error, :no_frame}
    else
      case :file.pread(device, from, width) do
        {:ok, window} -> found(window, from, info)
        :eof -> {:error, :no_frame}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp wanted(%{sample: sample, rate: rate}, ms, info) do
    sample
    |> Kernel.+(div(ms * rate, 1000))
    |> max(0)
    |> min(last_sample(info))
  end

  defp last_sample(%{samples: 0}), do: :infinity
  defp last_sample(%{samples: samples}), do: samples - 1

  # The last frame that begins at or before the sample that the caller wants. A
  # bisection narrows the range, and a walk of a few frames finishes it, because
  # another probe of a narrow range reads as much as the walk does.
  defp seek(device, wanted, info, limit) do
    with {:ok, first} <- frame_at(device, info.audio_start, limit, info) do
      {:ok, bisect(device, wanted, info, limit, info.audio_start, limit, first, @max_probes)}
    end
  end

  defp bisect(device, wanted, info, limit, lo, hi, best, probes)
       when probes > 0 and hi - lo > @narrow do
    middle = div(lo + hi, 2)

    case frame_at(device, middle, hi, info) do
      {:ok, %{sample: sample} = frame} when sample <= wanted ->
        bisect(device, wanted, info, limit, frame.byte + 1, hi, frame, probes - 1)

      _other ->
        bisect(device, wanted, info, limit, lo, middle, best, probes - 1)
    end
  end

  defp bisect(device, wanted, info, limit, _lo, _hi, best, _probes) do
    step(device, wanted, info, limit, best, @max_steps)
  end

  defp step(_device, _wanted, _info, _limit, best, 0), do: best

  defp step(device, wanted, info, limit, best, steps) do
    case frame_at(device, best.byte + 1, limit, info) do
      {:ok, %{sample: sample} = next} when sample <= wanted ->
        step(device, wanted, info, limit, next, steps - 1)

      _other ->
        best
    end
  end

  # A candidate for each place that the two bytes of a sync word appear, and the CRC
  # of the header says which of them is a frame.
  defp found(window, from, info) do
    window
    |> :binary.matches(@syncs)
    |> Enum.find_value(fn {index, _length} ->
      case header(window, index, info) do
        {:ok, frame} -> {:ok, %{frame | byte: from + index}}
        :error -> nil
      end
    end)
    |> case do
      nil -> {:error, :no_frame}
      found -> found
    end
  end

  defp header(window, index, info) do
    with <<0xFF, second, third, fourth, rest::binary>> <-
           binary_part(window, index, min(@max_header_bytes, byte_size(window) - index)),
         true <- (second &&& 0xFC) == 0xF8,
         0 <- second >>> 1 &&& 0x01,
         0 <- fourth &&& 0x01,
         {:ok, block_code, rate_code} <- codes(third),
         {:ok, number, used} <- coded_number(rest),
         {:ok, blocks, after_block} <- block_size(block_code, rest, used),
         {:ok, after_rate} <- rate_bytes(rate_code, after_block),
         {:ok, rate} <- rate_of(rate_code, info),
         true <- checked(window, index, after_rate),
         {:ok, sample} <- sample_of(second &&& 0x01, number, blocks, info) do
      {:ok, %{byte: index, sample: sample, rate: rate}}
    else
      _other -> :error
    end
  end

  # A block size of 0 is reserved, a rate of 15 is invalid, and a channel assignment
  # above 10 is reserved. Each one names a header that no encoder wrote.
  defp codes(third) do
    block_code = third >>> 4
    rate_code = third &&& 0x0F

    if block_code == 0 or rate_code == 15, do: :error, else: {:ok, block_code, rate_code}
  end

  # The blocking strategy says what the coded number is. A file of many block sizes
  # carries the number of the first sample of the frame, and a file of one carries the
  # number of the frame, so the sample is the product.
  #
  # **The product uses the block size of the stream, and not the one of this frame.**
  # The last frame of a track holds whatever is left, and its header names that
  # smaller size. A product of the frame number and that size named a sample near the
  # start of the track, so a skip to the end of a 30 second file reported that it
  # moved 7.2 seconds backward.
  defp sample_of(0, number, _blocks, %{block: block}) when block > 0, do: {:ok, number * block}
  defp sample_of(0, _number, _blocks, _info), do: :error
  defp sample_of(1, number, _blocks, _info), do: {:ok, number}

  defp block_size(6, rest, used) do
    case rest do
      <<_skipped::binary-size(^used), blocks, _more::binary>> -> {:ok, blocks + 1, used + 1}
      _other -> :error
    end
  end

  defp block_size(7, rest, used) do
    case rest do
      <<_skipped::binary-size(^used), blocks::16, _more::binary>> -> {:ok, blocks + 1, used + 2}
      _other -> :error
    end
  end

  defp block_size(code, _rest, used) do
    case Map.fetch(@blocks, code) do
      {:ok, blocks} -> {:ok, blocks, used}
      :error -> :error
    end
  end

  defp rate_bytes(12, used), do: {:ok, used + 1}
  defp rate_bytes(code, used) when code in [13, 14], do: {:ok, used + 2}
  defp rate_bytes(_code, used), do: {:ok, used}

  # A rate code of 0 says that the rate is in STREAMINFO, and a code of 12 to 14 says
  # that it is in the bytes that follow the header. This reads neither: the rate of
  # the file is what a skip needs, and STREAMINFO holds it for every file.
  defp rate_of(_code, %{rate: rate}) when rate > 0, do: {:ok, rate}
  defp rate_of(code, _info), do: Map.fetch(@rates, code)

  # The CRC covers the sync word, the flags, the coded number and whatever follows
  # them, and the byte after all of that holds it.
  defp checked(window, index, after_rate) do
    covered = 4 + after_rate

    case window do
      <<_before::binary-size(^index), header::binary-size(^covered), crc, _rest::binary>> ->
        crc8(header) == crc

      _other ->
        false
    end
  end

  defp crc8(bytes), do: crc8(bytes, 0)

  defp crc8(<<>>, crc), do: crc

  defp crc8(<<byte, rest::binary>>, crc) do
    crc8(rest, elem(@crc_table, bxor(crc, byte)))
  end

  # The number of the frame, or of the first sample of it, in the encoding that UTF-8
  # uses. FLAC widens it to 36 bits, so a number takes up to 7 bytes.
  defp coded_number(<<byte, _rest::binary>>) when byte < 0x80, do: {:ok, byte, 1}

  defp coded_number(<<byte, rest::binary>>) do
    with {:ok, count, value} <- leading(byte),
         {:ok, number} <- continued(rest, count, value) do
      {:ok, number, count + 1}
    end
  end

  defp coded_number(_other), do: :error

  defp leading(byte) when (byte &&& 0xE0) == 0xC0, do: {:ok, 1, byte &&& 0x1F}
  defp leading(byte) when (byte &&& 0xF0) == 0xE0, do: {:ok, 2, byte &&& 0x0F}
  defp leading(byte) when (byte &&& 0xF8) == 0xF0, do: {:ok, 3, byte &&& 0x07}
  defp leading(byte) when (byte &&& 0xFC) == 0xF8, do: {:ok, 4, byte &&& 0x03}
  defp leading(byte) when (byte &&& 0xFE) == 0xFC, do: {:ok, 5, byte &&& 0x01}
  defp leading(0xFE), do: {:ok, 6, 0}
  defp leading(_byte), do: :error

  defp continued(_rest, 0, value), do: {:ok, value}

  defp continued(<<byte, rest::binary>>, count, value) when (byte &&& 0xC0) == 0x80 do
    continued(rest, count - 1, value <<< 6 ||| (byte &&& 0x3F))
  end

  defp continued(_rest, _count, _value), do: :error

  defp scan_width(%{max_frame: 0}), do: @scan_bytes

  defp scan_width(%{max_frame: max_frame}),
    do: min(2 * max_frame + @max_header_bytes, @scan_bytes)

  # Each metadata block names its own length and says whether it is the last one, so
  # this reads the chain and the byte after the last block is where the audio begins.
  defp blocks(device, at, info) do
    case :file.pread(device, at, 4) do
      {:ok, <<last::1, type::7, length::24>>} ->
        info = if type == 0, do: streaminfo(device, at + 4), else: info
        next = at + 4 + length

        if last == 1,
          do: audio_at(info, next),
          else: blocks(device, next, info)

      _other ->
        {:error, :no_stream_info}
    end
  end

  defp audio_at(nil, _next), do: {:error, :no_stream_info}
  defp audio_at({:error, reason}, _next), do: {:error, reason}
  defp audio_at({:ok, info}, next), do: {:ok, Map.put(info, :audio_start, next)}

  defp streaminfo(device, at) do
    case :file.pread(device, at, 34) do
      {:ok,
       <<min_block::16, _max_block::16, _min_frame::24, max_frame::24, rate::20, channels::3,
         _bits::5, samples::36, _md5::binary-size(16)>>} ->
        {:ok,
         %{
           rate: rate,
           block: min_block,
           channels: channels + 1,
           samples: samples,
           max_frame: max_frame
         }}

      _other ->
        {:error, :no_stream_info}
    end
  end
end
