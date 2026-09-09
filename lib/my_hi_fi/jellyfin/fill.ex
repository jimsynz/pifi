defmodule MyHiFi.Jellyfin.Fill do
  @moduledoc """
  Write the library of a Jellyfin server into the catalogue.

  An artist and an album each become a `MyHiFi.Playback.Item` of the kind
  `:container`, and a track becomes one of the kind `:track`. Every source fills the
  catalogue this way, and the browse tree then needs no knowledge of Jellyfin.

  ## What identifies an item

  The identifier of the server identifies the item here as well. Jellyfin gives one
  identifier to each thing that it holds, so an artist, an album and a track never
  collide and `source_ref` needs no name in front of it.

  ## What the tree looks like

  An album names its artist with `parent_id`, and a track names its album. **An
  artist is the one container with no parent**, so the Artists branch is one filter
  and it needs no facet and no column of its own. An album whose artist the server
  does not name goes under one container that this module keeps for those, or it
  would stand beside the artists in that branch.

  ## What a track holds, and what it does not

  `transport` is `:download` and `format` is the codec that the server sends. Both
  are columns, because `MyHiFi.Playback.Item` decides which favourites this device
  reads on to the card, and that read must ask no service. `byte_size` is a column
  for the same reason: the read asks whether the card holds room before it begins.
  See `MyHiFi.Playback.FavouriteAudio`.

  **A track holds no `url`.** The address of the audio carries the access token, and
  a token changes when a person links the device again.
  `MyHiFi.Source.Jellyfin.resolve/1` builds the address at the time of play, from
  the token that the device holds then.

  **A track keeps no place.** A song is not an episode: a person who stops half way
  through one does not want the second half of it tomorrow. See `keeps_place?` of
  `MyHiFi.Playback.Item`.

  ## Why it writes in bulk

  A library holds tens of thousands of tracks, and section 17 of the specification
  measures an Ash write at 11.8 ms against 2.21 ms for the same insert in plain SQL.
  A write for each row would take an hour of the card. `Ash.bulk_create/4` writes one
  statement for each batch, and the sync gives it one page at a time.
  """

  require Ash.Query

  alias MyHiFi.Artwork
  alias MyHiFi.Jellyfin.Server
  alias MyHiFi.Playback
  alias MyHiFi.Playback.Item

  @source "jellyfin"
  @unknown_artist_ref "jellyfin-artist-unknown"

  @doc """
  The name of this source in an address, and in the `source` column of an item.

      iex> MyHiFi.Jellyfin.Fill.source()
      "jellyfin"
  """
  @spec source() :: String.t()
  def source, do: @source

  @doc "The `source_ref` of the container that holds an album with no artist."
  @spec unknown_artist_ref() :: String.t()
  def unknown_artist_ref, do: @unknown_artist_ref

  @doc "Write one page of artists, and give the number that it wrote."
  @spec artists([Server.entry()]) :: non_neg_integer()
  def artists(entries), do: write(entries, :container)

  @doc """
  Write one page of albums, and give the number that it wrote.

  An album whose artist the server does not name goes under one container that this
  module keeps for those.
  """
  @spec albums([Server.entry()]) :: non_neg_integer()
  def albums([]), do: 0

  def albums(entries) do
    if Enum.any?(entries, &is_nil(&1.parent_ref)), do: unknown_artist()

    entries
    |> Enum.map(&%{&1 | parent_ref: &1.parent_ref || @unknown_artist_ref})
    |> write(:container)
  end

  @doc "Write one page of tracks, and give the number that it wrote."
  @spec tracks([Server.entry()]) :: non_neg_integer()
  def tracks(entries), do: write(entries, :track)

  defp write([], _kind), do: 0

  # **The stamp goes on here, and not in `to_item/3`.** That function holds a clause
  # for a container and a clause for a track, and a stamp on one of them alone made
  # each artist and each album look like a row that the server no longer holds. The
  # read then removed them, and it took every track with them. One place cannot be
  # missed by a clause that a later version adds.
  defp write(entries, kind) do
    parents = parents(entries)
    seen_at = DateTime.utc_now()

    ask_for_pictures(entries, kind)

    entries
    |> Enum.map(&to_item(&1, kind, parents))
    |> Enum.map(&Map.put(&1, :last_seen_at, seen_at))
    |> Ash.bulk_create!(Item, :upsert,
      upsert?: true,
      upsert_identity: :source_ref,
      # The list is the guarantee: a second read of the server writes what the
      # server owns, and it touches nothing of the person. `favourite?`,
      # `position_ms`, `position_bytes`, `played?` and `last_played_at` are absent
      # on purpose.
      upsert_fields: [
        :title,
        :subtitle,
        :artwork_url,
        :duration_ms,
        :byte_size,
        :last_seen_at,
        :published_at,
        :release_year,
        :added_at,
        :number,
        :disc,
        :parent_id,
        :transport,
        :container_format,
        :format,
        :keeps_place?
      ],
      return_errors?: true
    )

    length(entries)
  end

  # **A row of a container draws its picture, so the picture must be on the card before
  # a person browses.** A list draws the address of a picture without reading anything,
  # and nothing on that path asks for one, so the read of the library is what asks. See
  # `MyHiFi.Artwork.thumbnail_path/1`.
  #
  # A track asks for none of its own. A list of tracks draws no picture, and the picture
  # of a track is the cover of its album far more often than not.
  defp ask_for_pictures(entries, :container) do
    Enum.each(entries, &Artwork.Worker.enqueue(&1.artwork_url))
  end

  defp ask_for_pictures(_entries, :track), do: :ok

  # One read for a whole page, and not one read for each row. A page of 200 tracks
  # holds far fewer albums than that, so the read is small and the map that it gives
  # goes away with the page.
  defp parents(entries) do
    refs =
      entries
      |> Enum.map(& &1.parent_ref)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case refs do
      [] ->
        %{}

      refs ->
        Item
        |> Ash.Query.filter(source == ^@source and source_ref in ^refs)
        |> Ash.read!()
        |> Map.new(&{&1.source_ref, &1.id})
    end
  end

  defp to_item(entry, :container, parents) do
    %{
      source: @source,
      source_ref: entry.ref,
      kind: :container,
      parent_id: parents[entry.parent_ref],
      title: entry.title,
      subtitle: entry[:subtitle],
      artwork_url: entry.artwork_url,
      published_at: entry[:published_at],
      release_year: entry[:release_year],
      added_at: entry[:added_at]
    }
  end

  defp to_item(entry, :track, parents) do
    %{
      source: @source,
      source_ref: entry.ref,
      kind: :track,
      parent_id: parents[entry.parent_ref],
      title: entry.title,
      subtitle: entry[:subtitle],
      artwork_url: entry.artwork_url,
      duration_ms: entry[:duration_ms],
      byte_size: entry[:byte_size],
      published_at: entry[:published_at],
      number: entry[:number],
      disc: entry[:disc],
      transport: :download,
      container_format: :none,
      format: entry[:format] || :mp3,
      live?: false,
      keeps_place?: false
    }
  end

  # **The stamp is not optional here.** `MyHiFi.Jellyfin.Sync.Library` removes each row
  # of this source that a whole read did not see, and `MyHiFi.Playback.Item` removes
  # what a container holds when that container goes. A row of this one with no stamp
  # would therefore take every album with no artist away with it.
  defp unknown_artist do
    Playback.upsert_item!(%{
      source: @source,
      source_ref: @unknown_artist_ref,
      kind: :container,
      title: "Unknown artist",
      last_seen_at: DateTime.utc_now()
    })
  end
end
