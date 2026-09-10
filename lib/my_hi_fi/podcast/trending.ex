defmodule MyHiFi.Podcast.Trending do
  @moduledoc """
  Write the popular shows of the Podcast Index into the catalogue.

  A person browses Trending, and that must not wait for the network, so a job reads the
  index and the page reads the catalogue. This is the shape that every branch which
  reaches a service uses.

  A show that the index names carries the facet `trending`. The list changes, so this
  removes the mark of a show that has left it and leaves the show itself: a person may
  have subscribed to it, and a search may name it again.

  The index gives an order, and `rank` of the item carries it, because a list sorts on a
  column and no data layer sorts on a facet.
  """

  require Ash.Query

  alias MyHiFi.Event
  alias MyHiFi.Playback
  alias MyHiFi.Playback.Facet
  alias MyHiFi.Playback.Item
  alias MyHiFi.Playback.ItemFacet
  alias MyHiFi.Podcast
  alias MyHiFi.Podcast.Fill
  alias MyHiFi.Podcast.Index

  @key "trending"
  @mark %Ash.Union{type: :boolean, value: true}

  @doc "The facet that marks a show of the trending list."
  @spec key() :: String.t()
  def key, do: @key

  @doc """
  Read the index, and mark the shows that it names.

  It returns the number of shows that it marked.
  """
  @spec run(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def run(options \\ []) do
    with {:ok, found} <- Index.trending(options) do
      facet = Playback.upsert_facet!(%{key: @key, value: @mark})
      unmark(facet)

      items = Enum.map(Enum.with_index(found), &store(&1, length(found)))
      Enum.each(items, &Playback.link_facet!(%{item_id: &1.id, facet_id: facet.id}))
      announce()

      {:ok, length(items)}
    end
  end

  # The first show of the index comes first, and `rank` sorts a list in descending
  # order, so the first one gets the largest number.
  defp store({attributes, index}, count) do
    show = Podcast.upsert_show_from_index!(Map.take(attributes, [:feed_url, :index_id]))
    item = Fill.show(Map.put(attributes, :rank, count - index))
    {:ok, _show} = Podcast.set_show_item(show, %{item_id: item.id})

    item
  end

  # A show that has left the list keeps its row, because a person may have subscribed
  # to it and a search may name it again. It loses the mark alone.
  defp unmark(facet) do
    ItemFacet
    |> Ash.Query.filter(facet_id == ^facet.id)
    |> Ash.read!()
    |> Enum.each(&Playback.unlink_facet!/1)
  end

  # A person presses the control of the settings page, or the schedule runs, and a page
  # that shows Trending reads the list again. A read that failed changes no item, so it
  # announces nothing.
  defp announce do
    Event.publish(:source, %Event.Source.Changed{
      source: MyHiFi.Source.Podcasts,
      ref: :trending
    })
  end

  @doc "The items that the index named at the last read, the most popular first."
  @spec query() :: Ash.Query.t()
  def query do
    Item
    |> Ash.Query.filter(exists(facets, key == ^@key))
    |> Ash.Query.sort(rank: :desc, sorted_title: :asc)
  end

  @doc """
  The order that the index gave, for the sort control of a page.

  See the `order` of `t:MyHiFi.Source.listing/0`. Without it a page draws a column of
  the title alone, Cinder drops the sort by `rank`, and the popular shows come back in
  the order of the alphabet.
  """
  @spec order() :: {String.t(), String.t()}
  def order, do: {"Popularity", "rank"}

  @doc false
  @spec facet_query() :: Ash.Query.t()
  def facet_query, do: Ash.Query.for_read(Facet, :by_key, %{key: @key})
end
