defmodule MyHiFi.Podcast.Fill do
  @moduledoc """
  Write a show and its episodes into the catalogue.

  A show becomes a `MyHiFi.Playback.Item` of the kind `:container`, and each episode
  becomes one of the kind `:track` that names it with `parent_id`. Every source fills
  the catalogue this way, and the browse tree then needs no knowledge of podcasts.

  ## What identifies an item

  A show is identified by its feed address, which is what identifies a
  `MyHiFi.Podcast.Show` as well.

  A `<guid>` identifies an episode inside its feed, and two feeds can hold the same
  one. `source_ref` of an item must be unique across the whole source, so the address
  of the feed goes in front of it. The name is therefore made from the feed alone, and
  no read of the catalogue is needed to build one.

  ## What is a column, and what is a facet

  A date and a length differ for each episode, so `published_at` and `duration_ms` are
  columns. The category of a show is a facet, and `MyHiFi.Podcast.Index` gives it.

  An episode keeps its place, because a person goes on from where they stopped on a
  later day. A show is a container, so it plays nothing and keeps nothing.
  """

  alias MyHiFi.Playback
  alias MyHiFi.Playback.Item

  @source "podcasts"

  @doc "The `source_ref` of the item of one show."
  @spec show_ref(String.t()) :: String.t()
  def show_ref(feed_url), do: feed_url

  @doc """
  The `source_ref` of the item of one episode.

  A `<guid>` is unique inside its feed and not outside it, so the address of the feed
  goes in front. A feed address carries no space, so a space parts the two.
  """
  @spec episode_ref(String.t(), String.t()) :: String.t()
  def episode_ref(feed_url, guid), do: feed_url <> " " <> guid

  @doc """
  Write one show, and give its item.

  It leaves `favourite?` alone, because a subscription belongs to the person.
  """
  @spec show(map()) :: Item.t()
  def show(attributes) do
    attributes
    |> write_show()
    |> categorise(attributes[:categories] || [])
  end

  # The index gives the categories of a show, and each one becomes a facet. The
  # Categories branch of the tree is then a plain read of the facets, and nothing asks
  # the index for a list: a person sees the categories of the shows that a device
  # gives.
  defp categorise(item, []), do: item

  defp categorise(item, names) do
    for name <- names do
      facet =
        Playback.upsert_facet!(%{key: "category", value: %Ash.Union{type: :string, value: name}})

      Playback.link_facet!(%{item_id: item.id, facet_id: facet.id})
    end

    item
  end

  defp write_show(attributes) do
    Playback.upsert_item!(%{
      source: @source,
      source_ref: show_ref(attributes.feed_url),
      kind: :container,
      title: attributes[:title] || "A show",
      description: attributes[:description],
      artwork_url: attributes[:artwork_url],
      # The index gives an order, and a list sorts on a column. A show that no list
      # ranks gets 0.
      rank: attributes[:rank] || 0
    })
  end

  @doc """
  Write the episodes of one show, and give the number that it wrote.

  `show_item` is what `show/1` gave.
  """
  @spec episodes(Item.t(), String.t(), [map()]) :: non_neg_integer()
  def episodes(_show_item, _feed_url, []), do: 0

  def episodes(show_item, feed_url, attributes) do
    attributes
    |> Enum.map(&to_item(&1, show_item, feed_url))
    |> Ash.bulk_create!(Item, :upsert,
      upsert?: true,
      upsert_identity: :source_ref,
      # The list is the guarantee: a second read of a feed writes what the publisher
      # owns, and it touches nothing of the person. `position_ms`, `position_bytes`,
      # `played?` and `favourite?` are absent on purpose.
      upsert_fields: [
        :title,
        :subtitle,
        :description,
        :artwork_url,
        :duration_ms,
        :published_at,
        :number,
        :url,
        :format,
        :parent_id
      ],
      return_errors?: true
    )

    length(attributes)
  end

  defp to_item(episode, show_item, feed_url) do
    %{
      source: @source,
      source_ref: episode_ref(feed_url, episode.guid),
      kind: :track,
      parent_id: show_item.id,
      title: episode[:title] || "An episode",
      subtitle: subtitle(episode),
      description: episode[:description],
      artwork_url: episode[:artwork_url],
      duration_ms: episode[:duration_ms],
      published_at: episode[:published_at],
      number: episode[:number],
      url: episode.audio_url,
      transport: :download,
      container_format: :none,
      format: format(episode[:mime_type]),
      live?: false,
      # A person goes on from where they stopped in an episode, on a later day.
      keeps_place?: true
    }
  end

  # The date tells a person which episode is new, and the length tells them whether
  # they have time for it. It is a column, so a page draws a list with no join.
  defp subtitle(%{published_at: nil, duration_ms: nil}), do: nil
  defp subtitle(%{published_at: nil, duration_ms: duration}), do: minutes(duration)
  defp subtitle(%{published_at: at, duration_ms: nil}), do: date(at)

  defp subtitle(%{published_at: at, duration_ms: duration}),
    do: "#{date(at)}, #{minutes(duration)}"

  defp date(at), do: Calendar.strftime(at, "%-d %b %Y")

  defp minutes(ms), do: "#{max(div(ms, 60_000), 1)} min"

  # 8771 of the 8773 episodes of the measurement hold `audio/mpeg`, and 2 hold
  # `audio/x-m4a`. MP4 needs a demultiplexer that this firmware does not hold, so an
  # episode of an unknown type gets `:unknown` and `resolve/1` refuses it.
  defp format("audio/mpeg"), do: :mp3
  defp format("audio/mp3"), do: :mp3
  defp format("audio/mpeg3"), do: :mp3
  defp format("audio/x-mpeg"), do: :mp3
  defp format("audio/aac"), do: :aac
  defp format("audio/aacp"), do: :aac
  defp format(_other), do: :unknown
end
