defmodule MyHiFi.Test.Podcasts do
  @moduledoc """
  Subscribe to a show the way that a person does.

  A subscription is a mark on the item of the show, so a test must write the item and
  mark it. `MyHiFi.Podcast.Show` holds the address of the feed and nothing that a
  person did.
  """

  require Ash.Query

  alias MyHiFi.Playback
  alias MyHiFi.Playback.Item
  alias MyHiFi.Podcast
  alias MyHiFi.Podcast.Fill

  @doc "Mark the show, and link it to its item. It gives the show."
  @spec subscribe(MyHiFi.Podcast.Show.t()) :: MyHiFi.Podcast.Show.t()
  def subscribe(show) do
    item = item_of(show)
    {:ok, _item} = Playback.set_favourite(item)

    show
  end

  @doc "Take the mark off the show. It gives the show."
  @spec unsubscribe(MyHiFi.Podcast.Show.t()) :: MyHiFi.Podcast.Show.t()
  def unsubscribe(show) do
    item = item_of(show)
    {:ok, _item} = Playback.clear_favourite(item)

    show
  end

  # A show that a test filled already holds its item, and a mark must not write the
  # title of the publisher away.
  defp item_of(show) do
    item = existing(show) || Fill.show(%{feed_url: show.feed_url, title: "A show"})
    {:ok, _show} = Podcast.set_show_item(show, %{item_id: item.id})

    item
  end

  defp existing(show) do
    Item
    |> Ash.Query.filter(source == "podcasts" and source_ref == ^show.feed_url)
    |> Ash.read_one!()
  end
end
