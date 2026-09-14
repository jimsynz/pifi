defmodule MyHiFi.Playback.Item.RemoveCache do
  @moduledoc """
  Removes what the cache holds for one source, and keeps the catalogue of it.

  A person who takes a source out of use asks for the room of it back. The eviction
  alone gives them nothing: it takes the coldest entry when the card runs short, so
  the albums of a server that a person stopped using stay on the card for as long as
  the card has room. A library of 53,105 items held 1.82 GB on a measurement of
  2026-09-09.

  **A mark holds nothing against this.** The audio of a favourite waits for an
  eviction like any other entry, and this removes it with the rest. A person who puts
  the source back in use reads the tracks that they marked again, because the mark is
  still on the row. See `MyHiFi.Playback.FavouriteAudio`.

  **The rows stay, and the files go.** The catalogue is small, and it carries the
  marks, the places and the played state of a person. A source that comes back
  therefore shows what it showed before, and it reads the audio and the pictures
  again.

  ## Two namespaces, and two ways to them

  - **The audio is in `download`, keyed by the identifier of the item.** The join of
    `MyHiFi.Playback.Item` therefore names each entry, and the number of them is small:
    the card holds the tracks that a person marked or played, and not a library.
  - **A picture is in `artwork`, keyed by the hash of its address.** No row of the
    cache names an item, so this reads the addresses that the items of the source
    carry and `MyHiFi.Artwork.remove_each/1` turns each one into a key. A publisher
    that uses one cover for 200 episodes names one address, so the list is of the
    pictures and not of the rows.

  The thumbnail of a picture is a variant of it, and a variant goes with its entry.
  See `MyHiFi.Cache.Entry.Changes.PurgeVariants`.
  """

  use Ash.Resource.Actions.Implementation

  alias MyHiFi.Artwork
  alias MyHiFi.Cache
  alias MyHiFi.Cache.Entry
  alias MyHiFi.Playback.Item
  alias MyHiFi.Player.Download

  require Ash.Query

  @impl true
  def run(input, _options, _context) do
    slug = input.arguments.source

    {:ok, remove_audio(slug) + Artwork.remove_each(addresses(slug))}
  end

  # The count comes first, because `MyHiFi.Cache.purge_all/1` reports that it worked
  # and no number. See that function.
  defp remove_audio(slug) do
    query =
      Ash.Query.filter(Entry, namespace == ^Download.namespace() and entry_key in ^keys(slug))

    count = Ash.count!(query)

    if count > 0, do: Cache.purge_all(query)

    count
  end

  # The key of an entry of the audio is the identifier of the item, and `holding_audio`
  # names the items that the card holds a file for.
  defp keys(slug) do
    Item
    |> Ash.Query.for_read(:holding_audio)
    |> Ash.Query.filter(source == ^slug)
    |> Ash.Query.select([:id])
    |> Ash.read!()
    |> Enum.map(& &1.id)
  end

  # **A stream, and one column of each row.** A library holds 53,105 items, and
  # AshSqlite supports no `DISTINCT`, so the rows arrive in pages and
  # `MyHiFi.Artwork.remove_each/1` takes each address one time. **Two rows of one album
  # name one address**, so the pictures are thousands where the rows are tens of
  # thousands. A track that names no address takes the picture of its container, and
  # that container is a row of the same source.
  defp addresses(slug) do
    Item
    |> Ash.Query.filter(source == ^slug and not is_nil(artwork_url))
    |> Ash.Query.select([:artwork_url])
    |> Ash.stream!()
    |> Stream.map(& &1.artwork_url)
  end
end
