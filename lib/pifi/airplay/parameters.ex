defmodule PiFi.AirPlay.Parameters do
  @moduledoc """
  Reads a `SET_PARAMETER` body, which is where the volume of a sender arrives.

  `PiFi.AirPlay.NowPlaying` reads the words and the picture of a track, and this reads
  the one thing a sender still sends the AirPlay 1 way. The body is text rather than a
  plist:

      volume: -24.000000

  ## The number is decibels, and it has a hole in it

  **A sender names an attenuation from -30 to 0**, where 0 is as loud as it goes, and
  **-144 is mute**. That is not the bottom of the range but a value of its own, far
  below the quietest real setting: scaled with the rest it works out at about -380%,
  so the clamp below is what makes it silence rather than nonsense.

  The map to a percentage is linear across the real range, which is what Shairport Sync
  does and what a person turning the slider on a telephone expects to hear.
  """

  # The loudest and the quietest an AirPlay sender names, in decibels.
  @loudest 0.0
  @quietest -30.0

  @doc """
  What one `SET_PARAMETER` body asks for, or `:ignore` for one this firmware does not
  read.

  The volume comes back as the percentage this device works in, so nothing above here
  has to know about decibels.

      iex> PiFi.AirPlay.Parameters.read("volume: 0.000000\\r\\n")
      {:ok, {:volume, 100}}

      iex> PiFi.AirPlay.Parameters.read("volume: -30.000000\\r\\n")
      {:ok, {:volume, 0}}

      iex> PiFi.AirPlay.Parameters.read("volume: -24.000000\\r\\n")
      {:ok, {:volume, 20}}

  Mute is its own value, below the quietest setting, and the clamp is what takes it.

      iex> PiFi.AirPlay.Parameters.read("volume: -144.000000\\r\\n")
      {:ok, {:volume, 0}}

  A sender that names a whole number names one this reads as well.

      iex> PiFi.AirPlay.Parameters.read("volume: -15\\r\\n")
      {:ok, {:volume, 50}}

  A sender sends the progress of a track here as well, which this device counts for
  itself.

      iex> PiFi.AirPlay.Parameters.read("progress: 1/2/3\\r\\n")
      :ignore
  """
  @spec read(binary()) :: {:ok, {:volume, 0..100}} | :ignore
  def read(body) when is_binary(body) do
    with [_whole, named] <- Regex.run(~r/^\s*volume:\s*(-?\d+(?:\.\d+)?)\s*$/m, body),
         {decibels, _rest} <- Float.parse(named) do
      {:ok, {:volume, percent(decibels)}}
    else
      _other -> :ignore
    end
  end

  def read(_body), do: :ignore

  defp percent(decibels) when decibels <= @quietest, do: 0
  defp percent(decibels) when decibels >= @loudest, do: 100

  defp percent(decibels) do
    round((decibels - @quietest) / (@loudest - @quietest) * 100)
  end
end
