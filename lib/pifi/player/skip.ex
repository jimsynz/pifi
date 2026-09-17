defmodule PiFi.Player.Skip do
  @moduledoc """
  Where a skip lands in the file of a track.

  A person asks for a number of milliseconds, forward or backward, and this gives the
  byte to read next and the time that it really moved. `PiFi.Player.FileSource`
  calls it, and `PiFi.Player` adds the time that it reports to the count that a
  person reads.

  ## Two strategies, and the shape of a frame decides which

  **MP3 and AAC name the length of each frame, and FLAC names the time of each
  frame.** That one difference gives two strategies, and `place/5` chooses by the
  codec.

  - `PiFi.Player.Mp3Frame` and `PiFi.Player.AdtsFrame` name bytes, so this module
    walks the frames and sums the time. The two sections below describe that walk.
  - `PiFi.Player.FlacFrame` names samples, so it bisects the file and needs neither
    a walk nor a measurement. Read that module for its own reasons.

  ## Forward is a walk, for a codec that names bytes

  `PiFi.Player.Mp3Frame.forward/4` adds the length of each frame until the sum
  reaches the time, so a forward skip is one walk and it needs nothing else. The walk
  reads what it steps over, which is 480 KB for 30 seconds of a 128 kbit/s file.

  A walk that meets the end of what the file has stops there and reports the time
  that it did move. A whole file then ends the stream, and the source marks the track
  played. A file that still grows waits for the bytes, which is what
  `PiFi.Player.FileSource` already does when the network is slower than the audio.

  ## Backward is a measurement, for a codec that names bytes

  A frame has no pointer to the frame before it, so nothing walks backward. This
  therefore chooses a byte and then measures what it chose:

  1. `PiFi.Player.Mp3Frame.bytes_of_ms/4` gives a candidate byte, from the bitrate
     of the audio at the current point.
  2. A walk from that candidate to the current point measures the real time between
     the two.
  3. A measurement that lands more than a tenth from the request moves the candidate
     one time, by the error of the first one, and measures again.

  **The time that this reports is measured and never estimated.** A file of one
  bitrate lands on the request. A file of many lands near it, and it names where it
  landed, so the count that a person reads stays correct.

  A file of one bitrate lands inside one frame at the first measurement, so the second
  one runs for a file of many bitrates alone. A third would read the disk again, for a
  control that a person presses several times in a row, and a skip that is one second
  from the request is a skip that a person calls correct.
  """

  alias PiFi.Player.AdtsFrame
  alias PiFi.Player.FlacFrame
  alias PiFi.Player.Mp3Frame

  # How far from the request a measurement may land before this measures again. A
  # tenth of 15 seconds is 1.5 seconds.
  #
  # The second measurement is cheap, because it reads the bytes that the first one
  # read and the operating system keeps those pages already.
  @tolerance 10

  @doc """
  The byte to read next, and the time that the skip moved.

  `from` is the byte that the reader is at now, and `limit` is the count of bytes that
  the file has: the size of a whole file, or the count that the download reports for
  one that still grows.

  `ms` is signed, so a backward skip is a negative number. The `ms` of the answer
  carries the same sign, and it is the time that this measured and not the time that
  the caller asked for.

  `format` names the codec of the file, and it decides which reader of frames answers.
  A format that no reader holds gives `{:error, {:no_frames, format}}`, and
  `PiFi.Player` refuses such a skip before it reaches the pipeline.
  """
  @spec place(:file.fd(), non_neg_integer(), integer(), non_neg_integer(), atom()) ::
          {:ok, %{byte: non_neg_integer(), ms: integer()}} | {:error, term()}
  def place(device, from, ms, limit, format)

  def place(_device, from, 0, _limit, _format), do: {:ok, %{byte: from, ms: 0}}

  # **FLAC needs no walk and no measurement.** Each header names the sample that its
  # frame begins at, so `PiFi.Player.FlacFrame` bisects the file and reports an
  # exact time. See that module for why a walk is impossible for this codec.
  def place(device, from, ms, limit, :flac), do: FlacFrame.place(device, from, ms, limit)

  def place(device, from, ms, limit, format) when ms > 0 do
    with {:ok, frames} <- frames(format) do
      frames.forward(device, from, ms, limit)
    end
  end

  def place(device, from, ms, limit, format) do
    with {:ok, frames} <- frames(format),
         {:ok, bytes} <- frames.bytes_of_ms(device, from, -ms, limit) do
      back(frames, device, from, -ms, from - bytes, limit)
    end
  end

  @doc """
  The reader of frames of one codec.

  Every reader gives `boundary_before/3`, which is what a resume needs, so
  `PiFi.Player.FileSource` reads this list as well as `PiFi.Player` does. A codec
  that this answers for is a codec that a person can move inside.
  """
  @spec frames(atom()) :: {:ok, module()} | {:error, term()}
  def frames(:mp3), do: {:ok, Mp3Frame}
  def frames(:aac), do: {:ok, AdtsFrame}
  def frames(:flac), do: {:ok, FlacFrame}
  def frames(format), do: {:error, {:no_frames, format}}

  # The start of the file is as far back as a skip reaches, so this measures that span
  # and gives it. A second measurement would ask for the same bytes again.
  defp back(frames, device, from, _wanted, candidate, limit) when candidate <= 0 do
    measured(frames, device, from, 0, limit)
  end

  defp back(frames, device, from, wanted, candidate, limit) do
    with {:ok, place} <- measured(frames, device, from, candidate, limit) do
      nearer(frames, device, from, wanted, place, limit)
    end
  end

  # A second candidate reaches past the start of the file when the first measurement
  # was much shorter than the request, so this keeps it at the start.
  defp measured(frames, device, from, candidate, limit) do
    with {:ok, start} <- frames.boundary_at(device, max(candidate, 0), limit),
         true <- start < from,
         {:ok, %{ms: ms}} <- frames.forward(device, start, :infinity, from) do
      {:ok, %{byte: start, ms: -ms}}
    else
      false -> {:error, :no_frame}
      {:error, reason} -> {:error, reason}
    end
  end

  # A span of no time gives no error to scale by, so this keeps the first answer.
  defp nearer(_frames, _device, _from, _wanted, %{ms: 0} = place, _limit), do: {:ok, place}

  defp nearer(frames, device, from, wanted, place, limit) do
    if near?(place.ms, wanted) do
      {:ok, place}
    else
      case measured(frames, device, from, scaled(from, wanted, place), limit) do
        {:ok, better} -> {:ok, better}
        {:error, _reason} -> {:ok, place}
      end
    end
  end

  defp near?(ms, wanted), do: abs(abs(ms) - wanted) * @tolerance <= wanted

  # A walk that stopped early gives a small time, and a scale by that error alone
  # would send the candidate a long way back. The walk that follows it would then read
  # many megabytes for one skip, so four times the first distance is the furthest that
  # a second candidate goes.
  defp scaled(from, wanted, %{byte: byte, ms: ms}) do
    distance = from - byte

    from - min(div(distance * wanted, -ms), distance * 4)
  end
end
