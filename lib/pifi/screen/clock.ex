defmodule PiFi.Screen.Clock do
  @moduledoc """
  The time of a track, as a person reads it on a screen.

  `PiFi.Peripheral.PiTft.Screen` and `PiFi.Peripheral.PirateAudio.Screen` both draw
  a time, and the two must read the same way. A person who moves from one screen to the
  other reads one device, so `1:37:12` on the large screen cannot be `97:12` on the
  small one.

  This is a part in the way that `PiFi.Screen.Battery` is one: it returns
  the words, and each screen decides the place, the size and the colour of them.

  The web page has its own, and it stays there. A browser has room for a label beside
  a time, and it names the hours in a way that 240 pixels cannot.
  """

  @doc """
  The time of a track, as minutes and seconds.

  An hour or more takes a third part, because a podcast episode runs that long and a
  person who reads "97:12" has to do the arithmetic.

      iex> PiFi.Screen.Clock.text(9_000)
      "0:09"

      iex> PiFi.Screen.Clock.text(5_832_000)
      "1:37:12"
  """
  @spec text(non_neg_integer()) :: String.t()
  def text(milliseconds) do
    seconds = div(milliseconds, 1000)
    minutes = div(seconds, 60)

    case div(minutes, 60) do
      0 -> "#{minutes}:#{pad(rem(seconds, 60))}"
      hours -> "#{hours}:#{pad(rem(minutes, 60))}:#{pad(rem(seconds, 60))}"
    end
  end

  defp pad(seconds), do: String.pad_leading(to_string(seconds), 2, "0")
end
