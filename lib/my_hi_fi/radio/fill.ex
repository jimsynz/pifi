defmodule MyHiFi.Radio.Fill do
  @moduledoc """
  Write the stations of Radio Browser into the catalogue.

  A station becomes one `MyHiFi.Playback.Item`, and its country, its language, its
  tags and its bitrate become `MyHiFi.Playback.Facet` rows that the item links to.
  Every source fills the catalogue this way, and the browse tree then needs no
  knowledge of internet radio.

  ## What is a column, and what is a facet

  The codec is `format` of the item, because a column filters and sorts and a facet
  does neither well. The click count is `rank`, because the station list is in the
  order that a person elsewhere chose. A country, a language, a tag and a bitrate are
  facets, because each one is a short list that a person browses.

  ## What the item says about playing, and what is true

  `transport` and `format` hold what the service claims. They are not the last word:
  `MyHiFi.Source.InternetRadio.resolve/1` reads an HLS playlist and the first page of
  an Ogg stream at the time of play, because the service reports the codec `OGG` for
  every codec inside that container. A user interface may read these, and the player
  must not.

  ## Why it writes in bulk

  Section 17 of the specification measures an Ash write at 11.8 ms, against 2.21 ms
  for the same insert in plain SQL. A country of 500 stations is 500 items and about
  3000 links, so a write for each row would take a minute of the card.
  `Ash.bulk_create/4` writes one statement for each batch.
  """

  alias MyHiFi.Playback
  alias MyHiFi.Playback.Facet
  alias MyHiFi.Playback.Item
  alias MyHiFi.Playback.ItemFacet

  @source "internet-radio"

  @doc """
  Write a list of stations, and give the number of items that it wrote.

  Each entry is what `MyHiFi.Radio.RadioBrowser` gives.
  """
  @spec stations([map()]) :: non_neg_integer()
  def stations([]), do: 0

  def stations(attributes) do
    items = write_items(attributes)
    by_ref = Map.new(items, &{&1.source_ref, &1.id})

    attributes
    |> facets_of()
    |> write_facets()
    |> link(attributes, by_ref)

    length(items)
  end

  defp write_items(attributes) do
    attributes
    |> Enum.map(&to_item/1)
    |> Ash.bulk_create!(Item, :upsert,
      upsert?: true,
      upsert_identity: :source_ref,
      # A bulk create needs this list, and the list is the guarantee: a second read of
      # the service writes what the service owns, and it touches nothing of the
      # person. `favourite?`, `position_ms`, `position_bytes`, `played?` and
      # `last_played_at` are absent on purpose.
      upsert_fields: [
        :title,
        :subtitle,
        :artwork_url,
        :url,
        :transport,
        :format,
        :live?,
        :rank
      ],
      return_records?: true,
      return_errors?: true
    )
    |> Map.fetch!(:records)
  end

  defp to_item(station) do
    %{
      source: @source,
      source_ref: station.remote_id,
      kind: :track,
      title: station.title,
      subtitle: subtitle(station),
      artwork_url: station.artwork_url,
      url: station.stream_url,
      transport: if(station.hls?, do: :hls, else: :http),
      format: format(station.codec),
      live?: true,
      rank: station.click_count || 0
    }
  end

  # The codec and the bitrate tell a person what to expect of the sound. This is a
  # column of the item and not a read of two facets, because a list draws one line
  # under each title and a join for each row of a page is waste.
  defp subtitle(%{codec: nil}), do: nil
  defp subtitle(%{codec: codec, bitrate: nil}), do: codec
  defp subtitle(%{codec: codec, bitrate: 0}), do: codec
  defp subtitle(%{codec: codec, bitrate: bitrate}), do: "#{codec}, #{bitrate} kbps"

  # The service names a codec in free text, and it reports `OGG` for each codec inside
  # that container. `MyHiFi.Source.InternetRadio.resolve/1` finds the true one.
  defp format(codec) when is_binary(codec) do
    case String.downcase(codec) do
      "mp3" -> :mp3
      "aac" -> :aac
      "aac+" -> :aac
      "aacp" -> :aac
      "flac" -> :flac
      "ogg" -> :vorbis
      "opus" -> :opus
      _other -> :unknown
    end
  end

  defp format(_codec), do: :unknown

  # One country writes one `country` facet, and 500 stations of it name that one row.
  defp facets_of(attributes) do
    attributes
    |> Enum.flat_map(&pairs_of/1)
    |> Enum.uniq()
  end

  defp pairs_of(station) do
    # A tag comes from free text, and one publisher writes "News" where another
    # writes "news". The facet list is the canonical one, so one tag is one row.
    tags =
      station.tags
      |> Kernel.||([])
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()
      |> Enum.map(&{"tag", %Ash.Union{type: :string, value: &1}})

    [
      country_pair(station.country_code),
      language_pair(station.language),
      bitrate_pair(station.bitrate)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.concat(tags)
  end

  defp country_pair(code) when is_binary(code) and code != "",
    do: {"country", %Ash.Union{type: :string, value: code}}

  defp country_pair(_code), do: nil

  defp language_pair(name) when is_binary(name) and name != "",
    do: {"language", %Ash.Union{type: :string, value: name}}

  defp language_pair(_name), do: nil

  defp bitrate_pair(rate) when is_integer(rate) and rate > 0,
    do: {"bitrate", %Ash.Union{type: :integer, value: rate}}

  defp bitrate_pair(_rate), do: nil

  defp write_facets([]), do: %{}

  defp write_facets(pairs) do
    pairs
    |> Enum.map(fn {key, value} -> %{key: key, value: value} end)
    |> Ash.bulk_create!(Facet, :upsert,
      upsert?: true,
      upsert_identity: :key_value,
      # The key and the value are the whole row, and they are the identity, so a
      # second write has nothing to change.
      upsert_fields: [:key],
      return_records?: true,
      return_errors?: true
    )
    |> Map.fetch!(:records)
    |> Map.new(&{{&1.key, &1.value}, &1.id})
  end

  defp link(by_pair, attributes, by_ref) when map_size(by_pair) == 0 do
    _unused = {attributes, by_ref}
    :ok
  end

  defp link(by_pair, attributes, by_ref) do
    attributes
    |> Enum.flat_map(fn station ->
      case Map.fetch(by_ref, station.remote_id) do
        {:ok, item_id} ->
          station
          |> pairs_of()
          |> Enum.map(&%{item_id: item_id, facet_id: Map.fetch!(by_pair, &1)})

        :error ->
          []
      end
    end)
    |> Ash.bulk_create!(ItemFacet, :upsert,
      upsert?: true,
      upsert_identity: :item_facet,
      upsert_fields: [:item_id],
      return_errors?: true
    )

    :ok
  end

  @doc "Remove the facets that no item holds any more."
  @spec tidy() :: non_neg_integer()
  def tidy do
    {:ok, removed} = Playback.destroy_orphan_facets()
    removed
  end
end
