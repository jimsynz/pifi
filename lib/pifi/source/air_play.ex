defmodule PiFi.Source.AirPlay do
  @moduledoc """
  AirPlay, as a source that a person can find.

  An iPhone, an iPad or a Mac lists this device beside the speakers of the house, and
  the audio goes straight from it to here. `PiFi.AirPlay.Server` answers the protocol;
  this is the face of it that a person meets.

  ## Why it is a source when it can browse nothing

  **It receives audio rather than offering it.** A telephone decides what plays, so
  nothing here resolves a track, seeks in one, or knows how long it is. There is no
  catalogue, no tree, and no row to press.

  `c:PiFi.Source.roots/0` therefore answers `{:error, __MODULE__}`, the way `Enumerable`
  says it cannot count a thing, and a page that meets that says what this is and how to
  send audio to it. `PiFi.Source.Spotify` is the same shape and answers the same way.

  ## Why the switch moved here

  This used to live in a settings page of its own. That page carried a good explanation
  and it was the wrong place to keep the switch: a person looking for where to turn
  AirPlay on had to already know it was not with the other music services. It is the
  argument `PiFi.Source.Spotify` records about the same mistake, and the explanation
  came with it into `description/0`.

  **One setting, and it is the one every source uses.** `PiFi.AirPlay.Monitor` hears
  `PiFi.Event.Source.EnabledChanged` and starts or stops the listener, so the switch a
  person sees and the port that is open cannot disagree.

  ## It is out of use until a person says otherwise

  `c:PiFi.Source.ready?/0` is `false`, and always will be. Every other source reads that
  as "this needs an address or a key"; here it is a question nobody has answered yet.
  **This opens a port**, so a device that nobody asked must leave it shut.
  """

  @behaviour PiFi.Source

  @doc false
  @impl PiFi.Source
  def title, do: "AirPlay"

  @doc false
  @impl PiFi.Source
  def icon, do: :airplay

  @doc false
  @impl PiFi.Source
  def capabilities, do: []

  @doc false
  @impl PiFi.Source
  def kinds, do: []

  @doc """
  There is nothing to browse. See the module documentation.

      iex> PiFi.Source.AirPlay.roots()
      {:error, PiFi.Source.AirPlay}

  """
  @impl PiFi.Source
  def roots, do: {:error, __MODULE__}

  @doc """
  The stream a sender is sending now.

  **The socket is found rather than carried.** A session lasts as long as one telephone
  stays connected, and `PiFi.Player` builds its pipeline again whenever the output
  changes — so a pid put in here would be a pid that had died by the time anything used
  it. `PiFi.AirPlay.Monitor` knows which session is current, and the pipeline asks it at
  the moment it builds.
  """
  @impl PiFi.Source
  def resolve(_item) do
    {:ok,
     %{
       uri: "airplay",
       headers: [],
       transport: :airplay,
       container: :none,
       # ALAC comes off the wire and `PiFi.AirPlay.PlaybackSource` has already decoded
       # it, so what reaches the pipeline is samples.
       format: :raw,
       # **A sender decides when it stops**, so there is no length to count against and
       # nothing to seek in.
       live?: true,
       position_ms: 0,
       key: nil,
       position_bytes: nil
     }}
  end

  @doc """
  The one item that stands for the input.

  **A stream from a telephone is shaped like a radio station.** A station is one item
  and the song playing on it arrives separately; this is the same, so the title, the
  artist and the artwork of whatever is playing ride in the fields radio already uses.

  One row, and not one for each track. A row for each track would write to the SD card
  for every song a person sends, for something that is in no catalogue and that nothing
  can play again. **An SD card has a finite number of writes.**
  """
  @spec item() :: PiFi.Playback.Item.t()
  def item do
    PiFi.Playback.upsert_item!(%{
      source: PiFi.Source.slug(__MODULE__),
      source_ref: "airplay",
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
      This device appears in the AirPlay list on an iPhone, an iPad or a Mac, and the \
      audio goes straight here.\
      """,
      """
      Anyone on your network can send to it, which is how AirPlay works. Leave it off \
      if that is not what you want.\
      """,
      """
      The sound card plays one thing at a time. If PiFi is already playing, stop it \
      before you send.\
      """
    ]
  end

  @doc false
  @impl PiFi.Source
  def ready?, do: false
end
