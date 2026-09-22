defmodule PiFi.Source.Spotify do
  @moduledoc """
  Spotify Connect, as a source that a person can find.

  The Spotify application on a phone or a laptop lists this device beside the speakers
  of the house, and the audio goes straight from Spotify to here. `PiFi.Spotify`
  supervises the daemon that speaks the protocol; this is the face of it that a person
  meets.

  ## Why it is a source when it can browse nothing

  **It receives audio rather than offering it.** A phone decides what plays, so nothing
  here resolves a track, seeks in one, or knows how long it is. There is no catalogue,
  no tree, and no row to press.

  That is a fact about the player, and it was allowed to decide something it had no
  business deciding: this lived in a settings section of its own, so a person looking
  for where to switch Spotify on had to already know it was not with the other music
  services. Where a person finds the switch and what the player can pull from are
  different questions.

  So it is a source, and `c:PiFi.Source.roots/0` and `c:PiFi.Source.resolve/1` return
  `{:error, __MODULE__}` in the way that `Enumerable` says it cannot count a thing. A
  page that meets that says what this is and how to send audio to it. See
  `t:PiFi.Source.unsupported/0`.

  AirPlay and a Bluetooth speaker are the same shape, and they will answer the same
  way.

  ## It is out of use until a person says otherwise

  `c:PiFi.Source.ready?/0` is `false`, and it is always `false`. Every other source
  reads that as "this needs an address or a key"; here it is a question that has not
  been answered.

  **This opens a port and the licence is the person's call**, so a device that nobody
  asked must leave it off. `PiFi.Source.enabled?/1` falls back to `ready?/0` for a
  source that no person has changed, which is exactly the behaviour wanted, and a
  person who turns it on writes a setting that wins over it from then on.
  """

  @behaviour PiFi.Source

  alias PiFi.Spotify.Loopback

  @doc false
  @impl PiFi.Source
  def title, do: "Spotify"

  @doc false
  @impl PiFi.Source
  def icon, do: :spotify

  @doc false
  @impl PiFi.Source
  def capabilities, do: []

  @doc false
  @impl PiFi.Source
  def kinds, do: []

  @doc """
  There is nothing to browse. See the module documentation.

      iex> PiFi.Source.Spotify.roots()
      {:error, PiFi.Source.Spotify}

  """
  @impl PiFi.Source
  def roots, do: {:error, __MODULE__}

  @doc """
  The loopback that librespot plays into.

  **This used to answer `{:error, __MODULE__}`, and the change is the point of the
  whole arrangement.** A cast went straight to the sound card, so nothing here had any
  audio to give and there was nothing to resolve. Now librespot plays into an ALSA
  loopback and the player reads the other half, so a cast is a stream like any other
  and this is the one thing that says where it is.

  `c:PiFi.Source.roots/0` still answers that it cannot: a telephone decides what plays,
  and there is still no tree to walk.
  """
  @impl PiFi.Source
  def resolve(_item) do
    {:ok,
     %{
       uri: Loopback.capture_device(),
       headers: [],
       transport: :capture,
       container: :none,
       # The samples are already samples. See `PiFi.Spotify.CaptureSource`.
       format: :raw,
       # **A cast has no end that this device knows.** A telephone decides when it
       # stops, so there is no length to count against and nothing to seek in.
       live?: true,
       position_ms: 0,
       key: nil,
       position_bytes: nil
     }}
  end

  @doc """
  The one item that stands for the input.

  **A cast is shaped like a radio station.** A station is an item and the song playing
  on it arrives separately, over ICY, as `stream_title`. Spotify is the same: the item
  is the input, and the title, the artist and the artwork of whatever is playing ride
  in the fields that radio already uses.

  So there is one row and not one for each track. A row for each track would write to
  the SD card for every song a person casts, for something that is in no catalogue and
  that nothing can play again. **An SD card has a finite number of writes.**
  """
  @spec item() :: PiFi.Playback.Item.t()
  def item do
    PiFi.Playback.upsert_item!(%{
      source: PiFi.Source.slug(__MODULE__),
      source_ref: "spotify",
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
      This device appears in the Spotify app beside the speakers of your house, and \
      Spotify sends the music straight here.\
      """,
      "It needs a Spotify Premium account.",
      {:warning,
       """
       This uses librespot, which is not made by Spotify. That project says connecting \
       to Spotify this way is probably against their terms. Turning it on is your call.\
       """},
      """
      The sound card plays one thing at a time. If PiFi is already playing, stop it \
      before you cast.\
      """
    ]
  end

  @doc false
  @impl PiFi.Source
  def ready?, do: false
end
