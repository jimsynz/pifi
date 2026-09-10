defmodule MyHiFi.Player.Skip do
  @moduledoc """
  Where a skip lands in the file of a track.

  A person asks for a number of milliseconds, forward or backward, and this gives the
  byte to read next and the time that it really moved. `MyHiFi.Player.FileSource`
  calls it, and `MyHiFi.Player` adds the time that it reports to the count that a
  person reads.

  ## Forward is a walk

  `MyHiFi.Player.Mp3Frame.forward/4` adds the length of each frame until the sum
  reaches the time, so a forward skip is one walk and it needs nothing else. The walk
  reads what it steps over, which is 480 KB for 30 seconds of a 128 kbit/s file.

  A walk that meets the end of what the file has stops there and reports the time
  that it did move. A whole file then ends the stream, and the source marks the track
  played. A file that still grows waits for the bytes, which is what
  `MyHiFi.Player.FileSource` already does when the network is slower than the audio.

  ## Backward is a measurement

  A frame has no pointer to the frame before it, so nothing walks backward. This
  therefore chooses a byte and then measures what it chose:

  1. `MyHiFi.Player.Mp3Frame.bytes_of_ms/4` gives a candidate byte, from the bitrate
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

  alias MyHiFi.Player.Mp3Frame

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

  This reads MP3 frames alone, so `MyHiFi.Player` refuses a skip of another format
  before it reaches the pipeline. 8771 of the 8773 episodes of the measurement of
  2026-08-24 hold `audio/mpeg`.
  """
  @spec place(:file.fd(), non_neg_integer(), integer(), non_neg_integer()) ::
          {:ok, %{byte: non_neg_integer(), ms: integer()}} | {:error, term()}
  def place(_device, from, 0, _limit), do: {:ok, %{byte: from, ms: 0}}

  def place(device, from, ms, limit) when ms > 0 do
    Mp3Frame.forward(device, from, ms, limit)
  end

  def place(device, from, ms, limit) do
    with {:ok, bytes} <- Mp3Frame.bytes_of_ms(device, from, -ms, limit) do
      back(device, from, -ms, from - bytes, limit)
    end
  end

  # The start of the file is as far back as a skip reaches, so this measures that span
  # and gives it. A second measurement would ask for the same bytes again.
  defp back(device, from, _wanted, candidate, limit) when candidate <= 0 do
    measured(device, from, 0, limit)
  end

  defp back(device, from, wanted, candidate, limit) do
    with {:ok, place} <- measured(device, from, candidate, limit) do
      nearer(device, from, wanted, place, limit)
    end
  end

  # A second candidate reaches past the start of the file when the first measurement
  # was much shorter than the request, so this keeps it at the start.
  defp measured(device, from, candidate, limit) do
    with {:ok, start} <- Mp3Frame.boundary_at(device, max(candidate, 0), limit),
         true <- start < from,
         {:ok, %{ms: ms}} <- Mp3Frame.forward(device, start, :infinity, from) do
      {:ok, %{byte: start, ms: -ms}}
    else
      false -> {:error, :no_frame}
      {:error, reason} -> {:error, reason}
    end
  end

  # A span of no time gives no error to scale by, so this keeps the first answer.
  defp nearer(_device, _from, _wanted, %{ms: 0} = place, _limit), do: {:ok, place}

  defp nearer(device, from, wanted, place, limit) do
    if near?(place.ms, wanted) do
      {:ok, place}
    else
      case measured(device, from, scaled(from, wanted, place), limit) do
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
