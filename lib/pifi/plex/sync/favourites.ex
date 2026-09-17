defmodule PiFi.Plex.Sync.Favourites do
  @moduledoc """
  Asks again for the audio of each marked item of this source.

  A mark asks for the audio at once, and a device that held no network at that moment
  reads nothing. `PiFi.AutoSync` runs this when the source is in use, the device has
  a link, and the network answers, so the audio arrives on the first moment that it
  can.

  **The rule that decides what reads names no source at all.**
  `PiFi.Playback.FavouriteAudio` reads `transport` and `keeps_place?` of an item, and
  this run only says which source to look at. A source that turned its server off
  therefore asks for nothing, and a source that no person uses asks for nothing, and
  neither answer needs a list of the sources anywhere.

  It puts one job in the queue for each item, and the job reads the tracks that the
  item covers. A person who marked twenty albums therefore gets twenty jobs and not one
  that runs for an hour.
  """

  use Ash.Resource.Actions.Implementation

  require Logger

  alias PiFi.Playback
  alias PiFi.Plex.Server
  alias PiFi.Source

  @impl true
  def run(_input, _options, _context) do
    if Source.enabled?(Source.Plex) and Server.configured?() do
      {:ok, ask()}
    else
      {:ok, 0}
    end
  end

  defp ask do
    marked = Playback.items_marked_for_audio!(Source.slug(Source.Plex))

    AshOban.run_triggers(marked, :cache_audio)

    Logger.info("Asking for the audio of #{length(marked)} marked items of Plex.")

    length(marked)
  end
end
