defmodule MyHiFi.Jellyfin.Sync.Library do
  @moduledoc """
  Copies the library of a Jellyfin server into the catalogue.

  `MyHiFi.AutoSync` runs this when the source is in use, the device holds a link,
  and the network answers. A person can also press a control on the settings page.

  ## It reads a page at a time

  A library holds tens of thousands of tracks, and this board holds 363.9 MB. The
  read therefore asks for one page, writes it, and lets it go. Nothing here holds
  the library, and the largest thing in memory is one page of 200 entries.

  The three kinds go in order, because an album names its artist and a track names
  its album. `MyHiFi.Jellyfin.Fill` reads the parent of each page out of the
  catalogue, so the artists must be there before the albums arrive.

  A read that fails leaves the catalogue as it stands. A person still browses what
  the device holds, and the next run reads the rest.
  """

  use Ash.Resource.Actions.Implementation

  require Logger

  alias MyHiFi.Event
  alias MyHiFi.Jellyfin.Fill
  alias MyHiFi.Jellyfin.Server
  alias MyHiFi.Source

  @kinds [:artists, :albums, :tracks]

  # A person who takes this source out of use expects the device to ask the server
  # for nothing. See `MyHiFi.Source.enabled?/1`.
  @impl true
  def run(_input, _options, _context) do
    if Source.enabled?(Source.Jellyfin) and Server.configured?() do
      sync()
    else
      {:ok, %{artists: 0, albums: 0, tracks: 0, skipped?: true}}
    end
  end

  defp sync do
    with {:ok, artists} <- read(:artists),
         {:ok, albums} <- read(:albums),
         {:ok, tracks} <- read(:tracks) do
      announce()

      Logger.info(
        "The Jellyfin library gave #{artists} artists, #{albums} albums and #{tracks} tracks."
      )

      {:ok, %{artists: artists, albums: albums, tracks: tracks, skipped?: false}}
    end
  end

  defp read(kind) when kind in @kinds, do: read(kind, 0, 0)

  defp read(kind, start, written) do
    case Server.page(kind, start) do
      {:ok, %{count: 0}} ->
        {:ok, written}

      {:ok, %{entries: entries, count: count, total: total}} ->
        next = start + count

        case fill(kind, entries) + written do
          all when next >= total -> {:ok, all}
          all -> read(kind, next, all)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fill(:artists, entries), do: Fill.artists(entries)
  defp fill(:albums, entries), do: Fill.albums(entries)
  defp fill(:tracks, entries), do: Fill.tracks(entries)

  # A page that shows a branch of this source reads it again. The read takes minutes
  # on a large library, so a person is often looking at the catalogue while this
  # writes it.
  defp announce do
    Event.publish(:source, %Event.Source.Changed{source: Source.Jellyfin, ref: :library})
  end
end
