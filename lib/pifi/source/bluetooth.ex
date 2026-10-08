defmodule PiFi.Source.Bluetooth do
  @moduledoc """
  A telephone playing to this device over Bluetooth, as a source a person can find.

  A person opens the Bluetooth settings of their telephone, finds this device beside
  the speakers of the house, and the audio comes straight here. `PiFi.Bluetooth` runs
  the daemons and `PiFi.Bluetooth.Sender` holds the telephone end of them; this is the
  face of it that a person meets.

  ## Why it is a source when it can browse nothing

  **It receives audio rather than offering it.** The telephone decides what plays, so
  nothing here resolves a track, seeks in one, or knows how long it is. There is no
  catalogue, no tree, and no row to press.

  `c:PiFi.Source.roots/0` therefore returns `{:error, __MODULE__}` in the way that
  `Enumerable` says it cannot count a thing, and a page that meets that says what this
  is and how to send audio to it. `PiFi.Source.Spotify` and `PiFi.Source.AirPlay` are
  the same shape and answer the same way. See `t:PiFi.Source.unsupported/0`.

  ## Bluetooth out is the same radio and a different switch

  This device has played *to* a Bluetooth speaker since before this existed, and that
  is an output rather than a source: `PiFi.Output.Alsa` lists a paired speaker beside
  the USB DAC. The two share the adapter, the daemons and the pairings, and `bluealsad`
  runs `a2dp-source` and `a2dp-sink` at once, so a person can listen on headphones and
  cast from a telephone without either switch knowing about the other.

  **The switch here turns the radio on if it is off**, because a person who turns this
  source on and finds nothing has been told nothing. Turning it off leaves the radio
  alone, because a person may be listening on Bluetooth headphones. See
  `PiFi.Bluetooth.Monitor`.

  ## It is out of use until a person says otherwise

  `c:PiFi.Source.ready?/0` is `false`, and it is always `false`. Every other source
  reads that as "this needs an address or a key"; here it is a question that has not
  been answered. A radio that answers anything in range is not what a device nobody
  asked for should be running, so `PiFi.Source.enabled?/1` falling back to `ready?/0`
  is exactly the behaviour wanted.
  """

  @behaviour PiFi.Source

  @doc false
  @impl PiFi.Source
  def title, do: "Bluetooth"

  @doc false
  @impl PiFi.Source
  def icon, do: :bluetooth

  @doc false
  @impl PiFi.Source
  def capabilities, do: []

  @doc false
  @impl PiFi.Source
  def kinds, do: []

  @doc """
  There is nothing to browse. See the module documentation.

      iex> PiFi.Source.Bluetooth.roots()
      {:error, PiFi.Source.Bluetooth}

  """
  @impl PiFi.Source
  def roots, do: {:error, __MODULE__}

  @doc """
  The capture that bluez-alsa serves for the telephone that is sending.

  **The ALSA name is not in the playable, and the reason is the same one AirPlay has.**
  The pipeline is built again whenever the output changes, and the telephone stays
  connected across that, so the name and the agreed rate are asked for when the
  pipeline is built rather than frozen here. See `PiFi.Player.Pipeline`.
  """
  @impl PiFi.Source
  def resolve(_item) do
    {:ok,
     %{
       uri: "bluetooth",
       headers: [],
       transport: :bluetooth,
       container: :none,
       # The samples are already samples. See `PiFi.Player.CaptureSource`.
       format: :raw,
       # **A telephone decides when it stops**, so there is no length to count against
       # and nothing to seek in.
       live?: true,
       position_ms: 0,
       key: nil,
       position_bytes: nil
     }}
  end

  @doc """
  The one item that stands for the input.

  **A telephone is shaped like a radio station.** A station is an item and the song
  playing on it arrives separately, over ICY, as `stream_title`. This is the same: the
  item is the input, and the title and the artist of whatever is playing ride in the
  fields that radio already uses.

  So there is one row and not one for each track. A row for each track would write to
  the SD card for every song a person plays, for something that is in no catalogue and
  that nothing can play again. **An SD card has a finite number of writes.**
  """
  @spec item() :: PiFi.Playback.Item.t()
  def item do
    PiFi.Playback.upsert_item!(%{
      source: PiFi.Source.slug(__MODULE__),
      source_ref: "bluetooth",
      title: title(),
      kind: :track,
      live?: true
    })
  end

  @doc false
  @impl PiFi.Source
  def description do
    [
      """
      This device appears in the Bluetooth settings of your phone beside the speakers \
      of your house, and your phone sends the music straight here.\
      """,
      """
      Open Settings → Bluetooth on this device and press Make discoverable, then pair \
      from your phone. The window closes by itself.\
      """,
      "The sound is SBC, which is what every phone has. A USB DAC sounds better.",
      "Playing from your phone replaces whatever PiFi is playing."
    ]
  end

  @doc false
  @impl PiFi.Source
  def ready?, do: false
end
