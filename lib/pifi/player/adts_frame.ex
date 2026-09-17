defmodule PiFi.Player.AdtsFrame do
  @moduledoc """
  Reads the frames of an AAC file in ADTS, to find a place inside it.

  This answers the same two questions for AAC that `PiFi.Player.Mp3Frame` answers
  for MP3: the boundary of a frame a little before a byte, for a resume, and the byte
  at a given time, for a skip. Read that module for why a resume needs a boundary and
  why a bitrate cannot turn a time into a byte. The reasons hold for both codecs, and
  the shape of the two modules is the same.

  ## What an ADTS header carries

  **An ADTS header names the length of its own frame**, in 13 bits, so a walk forward
  needs no table of bitrates. It also names the sampling frequency by an index, and a
  frame holds 1024 samples for each raw data block that it carries. The length in
  bytes and the length in time therefore both come from the header, which is what a
  walk of a file of many bitrates needs.

  This is the one real difference from MP3: that codec names a bitrate and a padding
  bit, and this one names the bytes.

  ## Why a walk forward, and not a scan backward

  A frame has no pointer to the frame before it, and the 12 bits of the sync word
  appear inside audio as well, so a scan backward would often stop on one of them.
  `boundary_before/3` therefore reads a window that ends at the byte, finds a frame
  inside it, and walks forward. A walk confirms itself: the length that a header
  gives lands exactly on the next sync word, so two frames in a row name a real one.

  ## Which files reach this

  A Jellyfin server sends AAC in ADTS, because `PiFi.Jellyfin.Server` asks for the
  `aac` container. An AAC track inside MP4 holds no ADTS header and never reaches
  here: `PiFi.Player.skippable?/1` reads the format of the playable, and a file of
  another shape gives no frame to this module in any case.
  """

  import Bitwise

  # The sampling frequency of each index that ADTS allows. Index 13 and 14 are
  # reserved, and 15 says that the rate is somewhere else, which ADTS does not allow.
  @rates {96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025,
          8_000, 7_350}

  # The length of a frame takes 13 bits, so no frame is longer than this and a window
  # needs this much room after the target to confirm a frame that ends past it.
  @max_frame_bytes 8191

  # How far before the target to look for a frame. A frame of 44100 Hz stereo at 128
  # kbit/s is about 380 bytes, so this window holds many of them.
  @search_bytes 8192

  # A header of 7 bytes carries everything that this reads. The 2 bytes of the CRC
  # come after it, and they are inside the length that the header names.
  @header_bytes 7

  # One raw data block holds this many samples, and a header names how many blocks
  # the frame carries.
  @block_samples 1024

  # How much audio a probe of the bitrate walks over. See
  # `PiFi.Player.Mp3Frame.bytes_of_ms/4`.
  @probe_ms 1000

  @doc """
  The first frame boundary at or after `byte`.

  `limit` is the byte to stop at, which is the count that the download reports, so
  nothing reads a part of the file that has not arrived.
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

  It returns 0 when the margin reaches the start of the file.
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

  **The answer is an estimate**, in the way that the answer of
  `PiFi.Player.Mp3Frame.bytes_of_ms/4` is. `PiFi.Player.Skip` measures the span
  that it chooses, and it reports what it measured.
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
  of `:infinity` measures the time between two bytes, which is what a backward skip
  needs.
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
  #
  # **This stops where a header no longer fits, and not where the longest frame no
  # longer fits.** The length of an ADTS frame takes 13 bits, so the longest one is
  # 8191 bytes and a window shorter than that would hold no frame at all under the
  # second rule. A window is that short near the start of a file, and while a
  # download holds its first bytes. `confirmed?/2` reads the length that the header
  # gives, so a frame that reaches past the window stays unconfirmed either way, and
  # a frame of 384 bytes inside a window of 3840 is now found.
  defp first_frame(window, index) do
    cond do
      index + @header_bytes > byte_size(window) -> nil
      confirmed?(window, index) -> index
      true -> first_frame(window, index + 1)
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

  # The sum is in microseconds, because one frame of 1024 samples at 44100 Hz runs
  # 23.220 ms and a walk of 30 seconds steps over 1292 of them.
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

  defp frame_at(device, byte) do
    case :file.pread(device, byte, @header_bytes) do
      {:ok, header} -> header(header)
      _other -> :error
    end
  end

  defp frame(window, index) when index + @header_bytes <= byte_size(window) do
    window |> binary_part(index, @header_bytes) |> header()
  end

  defp frame(_window, _index), do: :error

  # The 12 bits of the sync word, then the layer, which ADTS holds at 00 always. The
  # length of the frame spans three bytes, and it counts the header with the audio.
  defp header(<<0xFF, second, third, fourth, fifth, sixth, seventh>>)
       when (second &&& 0xF0) == 0xF0 do
    layer = second >>> 1 &&& 0x03
    index = third >>> 2 &&& 0x0F
    length = (fourth &&& 0x03) <<< 11 ||| fifth <<< 3 ||| sixth >>> 5
    blocks = (seventh &&& 0x03) + 1

    with true <- layer == 0x00,
         true <- length >= @header_bytes,
         {:ok, rate} <- rate(index) do
      {:ok, length, div(blocks * @block_samples * 1_000_000, rate)}
    else
      _other -> :error
    end
  end

  defp header(_other), do: :error

  defp rate(index) when index < tuple_size(@rates), do: {:ok, elem(@rates, index)}
  defp rate(_index), do: :error
end
