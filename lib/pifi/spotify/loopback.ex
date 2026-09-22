defmodule PiFi.Spotify.Loopback do
  @moduledoc """
  The ALSA loopback that Spotify plays into and this firmware reads out of.

  **The sound card holds one program at a time**, and librespot used to open it
  directly. So a cast reached a device that was already playing and got nothing, the
  knob did nothing while it played, and the screen showed no track: the audio never
  passed through `PiFi.Player` at all.

  `snd-aloop` is a card with two halves wired together. librespot plays to
  `hw:Loopback,0,0` and this firmware captures `hw:Loopback,1,0`, so `aplay` stays the
  only program that opens the real card and a cast is a stream like any other.

  ## The capture side never stops

  **It hands over a full-rate stream of digital silence while nothing plays**, which a
  measurement on a board confirmed: three seconds of `arecord` with nothing at all
  opening the playback side gave 529200 bytes, every one of them zero, which is exactly
  44100 x 2 x 2 x 3.

  So frames arriving cannot be the signal that a cast began. A pipeline started on data
  would start at once, never stop, hold the card for ever and lock the player out — the
  fault this exists to remove, arrived at from the other side. librespot says when it
  opens and closes its sink, and that is what starts and stops the capture.

  ## It loads when a person turns Spotify on

  A device that nobody asked for this carries no extra card, which is the rule
  `PiFi.Spotify` already follows for the port. `PiFi.Output.Alsa` hides the card from
  the outputs a person can choose in any case, because a loopback is a pipe between two
  programs and not a thing to listen to.
  """

  require Logger

  @modprobe "/sbin/modprobe"
  @module "snd-aloop"

  # One substream, because one telephone casts at a time and each substream costs
  # buffers. The module gives two devices by default, which is the playback half and
  # the capture half, and that is what this needs.
  @options ["pcm_substreams=1"]

  @card "Loopback"
  @cards_path "/proc/asound/cards"

  @doc """
  The name that librespot plays to.

      iex> PiFi.Spotify.Loopback.playback_device()
      "hw:Loopback,0,0"
  """
  @spec playback_device() :: String.t()
  def playback_device, do: "hw:#{@card},0,0"

  @doc """
  The name that this firmware captures from.

  **It is device 1 and not device 0.** The two halves of a loopback are crossed: what
  is written to `0,0` is read from `1,0`.

      iex> PiFi.Spotify.Loopback.capture_device()
      "hw:Loopback,1,0"
  """
  @spec capture_device() :: String.t()
  def capture_device, do: "hw:#{@card},1,0"

  @doc """
  Whether the card is there now.
  """
  @spec loaded?() :: boolean()
  def loaded? do
    case File.read(@cards_path) do
      {:ok, contents} -> String.contains?(contents, @card)
      {:error, _reason} -> false
    end
  end

  @doc """
  Make sure the card is there.

  It returns `:ok` for a card that was already loaded, so a caller may ask again
  without a read first.

  **A host has no `modprobe` and no `/proc/asound`**, so this says so and does not
  raise: the tests of everything above it run on a laptop.
  """
  @spec ensure_loaded() :: :ok | {:error, term()}
  def ensure_loaded do
    cond do
      loaded?() -> :ok
      not File.exists?(@modprobe) -> {:error, :no_modprobe}
      true -> load()
    end
  end

  defp load do
    case System.cmd(@modprobe, [@module | @options], stderr_to_stdout: true) do
      {_output, 0} ->
        Logger.info("The ALSA loopback is up, so Spotify can play through the player.")

        :ok

      {output, code} ->
        Logger.warning("#{@module} did not load (#{code}): #{String.trim(output)}")

        {:error, {:modprobe, code}}
    end
  end
end
