defmodule MyHiFi.Plex.Fill do
  @moduledoc """
  Write the library of a Plex server into the catalogue.

  An artist and an album each become a `MyHiFi.Playback.Item` of the kind
  `:container`, and a track becomes one of the kind `:track`. Every source fills the
  catalogue this way, and the browse tree then needs no knowledge of Plex.

  ## What identifies an item

  Plex calls it the rating key, and it gives one to each thing that it serves, so an
  artist, an album and a track never collide and `source_ref` needs no name in front
  of it. **A server gives that key as a number in some answers and as text in
  others**, and `MyHiFi.Plex.Server` writes it as text in every one.

  ## What the tree looks like

  An album names its artist with `parent_id`, and a track names its album. **An artist
  is the one container with no parent**, so the Artists branch is one filter and it
  needs no facet and no column of its own. An album whose artist the server does not
  name goes under one container that this module keeps for those, or it would stand
  beside the artists in that branch.

  ## What a person reads about an artist and about a record

  `description` carries `summary` of Plex, which is the life of an artist and the
  review of a record. The listing gives it, so no read of its own is needed, and a
  sample of one real library on 2026-09-14 held one for 74% of its albums.

  ## What a track carries, and what it does not

  `transport` is `:download`, and `format` is the codec that the server sends.
  `container_format` is `:ogg` for a file of that wrapper and `:none` for every other,
  because Ogg carries both Vorbis and FLAC and the pipeline builds a different graph
  for each. All three are columns, because `MyHiFi.Playback.Item` decides which
  favourites this device reads on to the card, and that read must ask no service.
  `byte_size` is a column for the same reason: the read asks whether the card has room
  before it begins.

  **A track of a codec that this firmware cannot read carries `:hls`.** Such a track
  arrives as a conversion that the server makes, which is a playlist and not a file, so
  the card holds no copy of it and no control moves inside it. See
  `MyHiFi.Source.Plex`.

  **A track carries no `url`, and it carries the path of its file.** The address of
  the audio carries the access token of the server, and that token changes when a
  person links the device again, so `MyHiFi.Source.Plex.resolve/1` builds the address
  at the time of play. What does not change is the path, and `MyHiFi.Playback.Item`
  keeps it under `source_key`: a read of the library is the one answer that names it,
  so a track that did not keep it would cost a read of the server for each play.

  **A track keeps no place.** A song is not an episode: a person who stops half way
  through one does not want the second half of it tomorrow. See `keeps_place?` of
  `MyHiFi.Playback.Item`.

  ## Why it writes in bulk

  A library has tens of thousands of tracks, and section 17 of the specification
  measures an Ash write at 11.8 ms against 2.21 ms for the same insert in plain SQL.
  A write for each row would take an hour of the card. `Ash.bulk_create/4` writes one
  statement for each batch, and the sync gives it one page at a time.
  """

  require Ash.Query

  alias MyHiFi.Artwork
  alias MyHiFi.Playback
  alias MyHiFi.Playback.Item
  alias MyHiFi.Playback.ItemFacet
  alias MyHiFi.Plex.Server

  @source "plex"
  @genre_key "plex-genre"
  @unknown_artist_ref "plex-artist-unknown"

  @doc """
  The name of this source in an address, and in the `source` column of an item.

      iex> MyHiFi.Plex.Fill.source()
      "plex"
  """
  @spec source() :: String.t()
  def source, do: @source

  @doc "The `source_ref` of the container for an album with no artist."
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

    written =
      entries
      |> Enum.map(&%{&1 | parent_ref: &1.parent_ref || @unknown_artist_ref})
      |> write(:container)

    link_genres(entries)

    written
  end

  @doc """
  The key that the genres of this source take in `MyHiFi.Playback.Facet`.

  **The key names the source, and it must.** Two library sources both hold a genre
  called `Rock`, and one shared key would give one facet row for the two of them. The
  lists would still be right, because `MyHiFiWeb.BrowseLive` reads the items of a facet
  by the source as well, and the count on the row of the facet would be the albums of
  both libraries.
  """
  @spec genre_key() :: String.t()
  def genre_key, do: @genre_key

  @doc "Write one page of tracks, and give the number that it wrote."
  @spec tracks([Server.entry()]) :: non_neg_integer()
  def tracks(entries), do: write(entries, :track)

  defp write([], _kind), do: 0

  # **The stamp goes on here, and not in `to_item/3`.** That function has a clause for
  # a container and a clause for a track, and a stamp on one of them alone would make
  # each artist and each album look like a row that the server no longer has. The read
  # then removes them, and it takes every track with them. One place cannot be missed
  # by a clause that a later version adds.
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
      # The list is the guarantee: a second read of the server writes what the server
      # owns, and it touches nothing of the person. `favourite?`, `position_ms`,
      # `position_bytes`, `played?` and `last_played_at` are absent on purpose.
      upsert_fields: [
        :title,
        :subtitle,
        :description,
        :artwork_url,
        :duration_ms,
        :byte_size,
        :last_seen_at,
        :release_year,
        :added_at,
        :number,
        :disc,
        :parent_id,
        :source_key,
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
  #
  # **One query for a whole page, and not one read for each entry.**
  # `MyHiFi.Artwork.ensure/1` makes one query for the list that it gets.
  defp ask_for_pictures(entries, :container) do
    entries
    |> Enum.map(& &1.artwork_url)
    |> Artwork.ensure()
  end

  defp ask_for_pictures(_entries, :track), do: :ok

  # One read for a whole page, and not one read for each row. A page of 50 tracks has
  # far fewer albums than that, so the read is small and the map that it builds goes
  # away with the page.
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

  # **The links go in one statement for each page, and not one for each genre.** A
  # library of 4360 albums names about four genres each, so a write for each of those
  # 17,000 links would cost the card a great deal, and a read of the library runs every
  # day.
  defp link_genres(entries) do
    case Enum.reject(entries, &(Map.get(&1, :genres, []) == [])) do
      [] -> :ok
      named -> write_links(named, facet_ids(named), ids_of(named))
    end
  end

  defp write_links(named, facets, items) do
    wanted =
      for entry <- named,
          item_id = items[entry.ref],
          name <- entry.genres,
          facet_id = facets[name] do
        {item_id, facet_id}
      end

    case Enum.reject(wanted, &MapSet.member?(held(items), &1)) do
      [] -> :ok
      rows -> insert_links(rows)
    end
  end

  # **A link that the table already holds costs no write.** An upsert of every link
  # would set the same values again, and that is a write of the card for each of the
  # thousands of links of a library, on every read of it. A read that changed nothing
  # therefore writes nothing at all now.
  #
  # `upsert?` stays for the rows that this does write, because a link is the identity of
  # itself and a second writer must not raise.
  defp held(items) do
    ids = Map.values(items)

    ItemFacet
    |> Ash.Query.filter(item_id in ^ids)
    |> Ash.read!()
    |> MapSet.new(&{&1.item_id, &1.facet_id})
  end

  defp insert_links(rows) do
    rows
    |> Enum.map(fn {item_id, facet_id} -> %{item_id: item_id, facet_id: facet_id} end)
    |> Ash.bulk_create!(ItemFacet, :upsert,
      upsert?: true,
      upsert_identity: :item_facet,
      upsert_fields: [:item_id],
      return_errors?: true
    )

    :ok
  end

  # **A facet that the table already holds costs no write.** A library names about a
  # hundred genres, so after the first pages every name of a page is a row that this
  # read finds. The read is of one key and it gives those hundred rows.
  defp facet_ids(named) do
    held =
      @genre_key
      |> Playback.facets_of_key!()
      |> Map.new(&{to_string(&1.value.value), &1.id})

    named
    |> Enum.flat_map(& &1.genres)
    |> Enum.uniq()
    |> Enum.reduce(held, fn name, acc ->
      Map.put_new_lazy(acc, name, fn -> written_facet(name) end)
    end)
  end

  defp written_facet(name) do
    Playback.upsert_facet!(%{
      key: @genre_key,
      value: %Ash.Union{type: :string, value: name}
    }).id
  end

  defp ids_of(entries) do
    refs = Enum.map(entries, & &1.ref)

    Item
    |> Ash.Query.filter(source == ^@source and source_ref in ^refs)
    |> Ash.read!()
    |> Map.new(&{&1.source_ref, &1.id})
  end

  defp to_item(entry, :container, parents) do
    %{
      source: @source,
      source_ref: entry.ref,
      kind: :container,
      parent_id: parents[entry.parent_ref],
      title: entry.title,
      subtitle: entry[:subtitle],
      description: entry[:description],
      artwork_url: entry.artwork_url,
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
      description: entry[:description],
      artwork_url: entry.artwork_url,
      duration_ms: entry[:duration_ms],
      byte_size: entry[:byte_size],
      number: entry[:number],
      disc: entry[:disc],
      source_key: entry[:part_key],
      transport: transport(entry[:format]),
      container_format: entry[:container_format] || :none,
      format: entry[:format] || :unknown,
      live?: false,
      keeps_place?: false
    }
  end

  # **A track that this device cannot read as it is arrives as a conversion**, and a
  # conversion is a playlist and not a file. The column says so, and two things then
  # follow with no rule of their own: `caches_audio?` of `MyHiFi.Playback.Item` names
  # `transport == :download`, so the card holds no copy of a file that nothing here can
  # read, and `MyHiFi.Player.skippable?/1` names the same, so the control is dead for a
  # stream that no reader moves inside. See `MyHiFi.Source.Plex`.
  defp transport(:unknown), do: :hls
  defp transport(nil), do: :hls
  defp transport(_format), do: :download

  # **The stamp is not optional here.** `MyHiFi.Plex.Sync.Library` removes each row of
  # this source that a whole read did not see, and `MyHiFi.Playback.Item` removes what
  # a container contains when that container goes. A row of this one with no stamp
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
