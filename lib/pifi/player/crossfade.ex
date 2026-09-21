defmodule PiFi.Player.Crossfade do
  @moduledoc """
  How long one track takes to give way to the next, and whether it does at all.

  A crossfade means the end of one track and the start of the next play together, the
  first getting quieter while the second gets louder. `PiFi.Player` reads this when it
  starts a track, hands the two pipelines to `PiFi.Output.APlayPort`, and that process
  sums them.

  **A device that no person changed plays with no crossfade**, because a crossfade is a
  taste and not an improvement: it suits a playlist of songs, and it takes the silence
  off the end of a live recording and talks over the first word of a podcast. So 0 is
  the default, and 0 means off.

  ## What it costs

  Two decoders run for the length of the fade, and the sum is arithmetic on every
  sample. A measurement on an AMD Ryzen 5 4500U gave 2.32% of one core for a ramped
  integer mix of 44100 Hz stereo `s24le`, which is 19% to 28% of one core of the A53 in
  this device. With the second decoder that is about a tenth of the machine, and only
  while a fade runs.

  ## What it does not apply to

  A live stream never ends, so nothing follows it to fade into. A change of sample rate
  cannot fade either: the rate is on the command line of `aplay`, and two rates cannot
  share a sound card. `PiFi.Output.APlayPort` refuses both, and a person then hears the
  change that they would have heard with this off.
  """

  alias PiFi.Settings

  @key "crossfade.seconds"

  # A fade longer than this is no longer a crossfade of two tracks: it is most of a
  # short song playing under most of another.
  @max_seconds 12

  @doc """
  The lengths that a person may choose, in seconds. 0 is off.

      iex> 0 in PiFi.Player.Crossfade.lengths()
      true
  """
  @spec lengths() :: [non_neg_integer()]
  def lengths, do: [0, 1, 2, 3, 5, 8, @max_seconds]

  @doc """
  The settings key that holds the length.

      iex> PiFi.Player.Crossfade.key()
      "crossfade.seconds"
  """
  @spec key() :: String.t()
  def key, do: @key

  @doc "The length of the fade in seconds, or 0 for none."
  @spec seconds() :: non_neg_integer()
  def seconds do
    with {:ok, %{value: value}} <- Settings.fetch(@key),
         {number, ""} <- Integer.parse(value),
         true <- number in 0..@max_seconds do
      number
    else
      _other -> 0
    end
  end

  @doc "The length of the fade in milliseconds, which is what `PiFi.Player` counts in."
  @spec length_ms() :: non_neg_integer()
  def length_ms, do: seconds() * 1_000

  @doc """
  Set the length of the fade, in seconds.

  0 turns it off, and the longest fade is #{@max_seconds} seconds. A track that is
  already playing keeps the length that it started with.
  """
  @spec set_seconds(non_neg_integer()) :: :ok | {:error, :out_of_range}
  def set_seconds(seconds) when is_integer(seconds) and seconds in 0..@max_seconds do
    Settings.put!(@key, to_string(seconds))

    :ok
  end

  def set_seconds(_seconds), do: {:error, :out_of_range}
end
