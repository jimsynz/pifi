defmodule MyHiFi.Player.Mp3Frame do
  @moduledoc """
  Reads the frames of an MP3 file, to find a place inside it.

  A resume needs the boundary of a frame a little before a byte. A skip needs the
  byte at a given time. Both come from the frame headers, and neither one needs a
  bitrate.

  ## What a resume needs

  A resume needs this for two reasons.

  **The middle of a frame is not a place where audio begins.** MAD skips bytes
  until it finds the next frame, one byte at a time. A read on the board on
  2026-08-24 measured 591 such skips after a resume, which is under two frames and
  about 50 ms.

  **The byte that a resume starts at is in front of what a person heard.**
  `MyHiFi.Player.FileSource` reports the byte that it read, and the pipeline runs a
  lead of one to four seconds over the sound. Opening the file at that byte steps
  over a second or two of speech. A person who resumes must hear a little again, and
  never lose a word, so this steps back before it aligns.

  ## What a skip needs

  **A bitrate cannot turn a time into a byte.** 11 of the 46 episodes of the
  measurement of 2026-08-24 hold more than one bitrate, and a resume that used one
  landed as much as 1994.6 s from the mark.

  A header carries the bitrate and the sample rate of its own frame, so it gives the
  length of that frame in bytes and its length in time. `forward/4` adds both, so it
  measures a real span of audio, and it is true for a file of many bitrates as well as
  for a file of one. `MyHiFi.Player.Skip` says what a backward skip then does with
  that measurement.

  ## Why it walks forward

  An MP3 frame has no pointer to the frame before it, so the only way back is to
  look for the 11 bits of a sync word. **Those bits appear inside audio as well**,
  and a scan backwards would often stop on one of them. That is the same trap that
  MAD meets when it skips a byte at a time.

  `boundary_before/3` reads a window that ends at the byte, finds a frame inside it,
  and walks forward. A walk forward confirms itself: the length that a header gives
  lands exactly on the next sync word, so two frames in a row name a real one. The
  window is about 10 KB and it parses a few hundred headers, so this needs no walk of
  the whole file.

  A backward skip meets the same wall, and `MyHiFi.Player.Skip` answers it in the
  same way: it chooses a byte before the point, and it walks forward from there to
  measure what it chose.
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
  # this many times over, so a window with no frame at all carries no audio.
  @search_bytes 8192

  # How much audio a probe of the bitrate walks over. One second is about 38 frames of
  # a 128 kbit/s file, so a file whose bitrate changes gives the rate of the audio
  # here and not the rate of one frame.
  @probe_ms 1000

  @doc """
  The first frame boundary at or after `byte`.

  `limit` is the byte to stop at. `MyHiFi.Player.FileSource` gives the count that the
  download reports, so nothing reads a part of the file that has not arrived.

  A window with no frame returns `{:error, :no_frame}`. That window is about 10
  KB, and one frame of any bitrate fits in it many times over, so a window with no
  frame carries no audio.
  """
  @spec boundary_at(:file.fd(), non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def boundary_at(_device, byte, limit) when byte >= limit, do: {:error, :no_frame}

  def boundary_at(device, byte, limit) do
    window_bytes = min(@search_bytes + @max_frame_bytes, limit - byte)

    case :file.pread(device, byte, window_bytes) do
      {:ok, window} -> boundary_in(window, byte)
      :eof -> {:error, :no_frame}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The last frame boundary at or before `byte` less `margin`.

  `margin` is in bytes and not in milliseconds, because the lead that this steps
  back over is itself a count of bytes: the reader read that many more than a person
  heard. A count of bytes therefore needs no bitrate, and it is true for a variable
  bitrate file as well as a constant one.

  It returns 0 when the margin reaches the start of the file. The first byte of a file
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

  @doc """
  How many bytes near `byte` hold `ms` of audio.

  A backward skip needs a byte to begin at, and no walk goes backward. This walks one
  second forward, which gives the bitrate of the audio here, and it scales that to the
  time that the caller asks for.

  **The answer is an estimate.** A file of one bitrate lands exactly, and a file of
  many lands near. `MyHiFi.Player.Skip` therefore measures the span that it chooses,
  and it reports what it measured.
  """
  @spec bytes_of_ms(:file.fd(), non_neg_integer(), pos_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def bytes_of_ms(device, byte, ms, limit) do
    with {:ok, start} <- boundary_at(device, byte, limit),
         {:ok, %{byte: reached, ms: walked}} <- forward(device, start, @probe_ms, limit) do
      scaled(reached - start, walked, ms)
    end
  end

  @doc """
  Walk forward from `byte`, and give the place that the walk reaches.

  It stops at the first bound that it meets: `ms` of audio, or `limit` bytes. An `ms`
  of `:infinity` therefore measures the time between two bytes, which is what a
  backward skip needs, and a `limit` that the walk meets first is a skip that reaches
  the end of what the file has.

  The byte that it returns is a frame boundary, and the milliseconds are the sum of the
  length of each frame that it stepped over. It never passes the time that the caller
  asks for, so it lands inside one frame of it, which is 26 ms of a 44100 Hz file.
  """
  @spec forward(:file.fd(), non_neg_integer(), pos_integer() | :infinity, non_neg_integer()) ::
          {:ok, %{byte: non_neg_integer(), ms: non_neg_integer()}} | {:error, term()}
  def forward(device, byte, ms, limit) do
    with {:ok, start} <- boundary_at(device, byte, limit) do
      {:ok, step(device, start, ms, limit, 0)}
    end
  end

  defp boundary(window, from, limit) do
    with {:ok, index} <- boundary_in(window, 0) do
      {:ok, from + walk(window, index, limit)}
    end
  end

  defp boundary_in(window, from) do
    case first_frame(window, 0) do
      nil -> {:error, :no_frame}
      index -> {:ok, from + index}
    end
  end

  # A frame that a header names, and a second one where its length says. Audio carries
  # the bits of a sync word often, and it carries two that agree on a length rarely.
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
    with {:ok, length, _microseconds} <- frame(window, index),
         {:ok, _next, _next_microseconds} <- frame(window, index + length) do
      true
    else
      _other -> false
    end
  end

  # The last boundary that is not past the target. Each step is one frame, so this
  # cannot land inside one.
  defp walk(window, index, limit) do
    case frame(window, index) do
      {:ok, length, _microseconds} when index + length <= limit ->
        walk(window, index + length, limit)

      _other ->
        index
    end
  end

  # The sum is in microseconds, because one frame of a 44100 Hz file runs 26.122 ms
  # and a walk of 30 seconds steps over 1149 of them. A sum of whole milliseconds
  # would lose 5 seconds of that walk.
  #
  # `:infinity` needs no clause of its own. A number is less than an atom in the term
  # order of Erlang, so the guard is correct for it.
  defp step(device, byte, ms, limit, microseconds) do
    case frame_at(device, byte) do
      {:ok, length, added}
      when byte + length <= limit and div(microseconds + added, 1000) <= ms ->
        step(device, byte + length, ms, limit, microseconds + added)

      _other ->
        %{byte: byte, ms: div(microseconds, 1000)}
    end
  end

  defp scaled(_bytes, 0, _ms), do: {:error, :no_frame}
  defp scaled(bytes, walked, ms), do: {:ok, div(bytes * ms, walked)}

  # One read of four bytes for each frame. The walk of a skip of 30 seconds therefore
  # asks the operating system 1149 times, and each answer comes from the cache of the
  # page that the read before it brought in.
  defp frame_at(device, byte) do
    case :file.pread(device, byte, 4) do
      {:ok, header} -> header(header)
      _other -> :error
    end
  end

  defp frame(window, index) when index + 4 <= byte_size(window) do
    window |> binary_part(index, 4) |> header()
  end

  defp frame(_window, _index), do: :error

  defp header(<<0xFF, second, third, _fourth>>) when (second &&& 0xE0) == 0xE0 do
    version = second >>> 3 &&& 0x03
    layer = second >>> 1 &&& 0x03
    index = third >>> 4 &&& 0x0F
    rate_index = third >>> 2 &&& 0x03
    padding = third >>> 1 &&& 0x01

    with true <- layer == 0x01,
         {:ok, kilobits} <- lookup(table(version), index),
         {:ok, rate} <- rate(version, rate_index) do
      {:ok, div(div(samples(version), 8) * kilobits * 1000, rate) + padding,
       div(samples(version) * 1_000_000, rate)}
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
