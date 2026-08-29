defmodule MyHiFi.Source.RootsTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Playback
  alias MyHiFi.Podcast.Fill, as: PodcastFill
  alias MyHiFi.Source.InternetRadio
  alias MyHiFi.Source.Podcasts
  alias MyHiFi.Test.Stations

  defp read({_name, %{query: query}}), do: Ash.read!(query)

  defp named(roots, name), do: Enum.find(roots, fn {found, _listing} -> found == name end)

  describe "internet radio" do
    test "it names its branches in the order that a person reads them" do
      assert ["Favourites", "Countries", "Tags"] = Enum.map(InternetRadio.roots(), &elem(&1, 0))
    end

    test "Favourites reads the items that a person marked, and no other source" do
      marked = Stations.create(%{})
      Stations.create(%{})
      {:ok, _marked} = Playback.set_favourite(marked)

      other = PodcastFill.show(%{feed_url: "https://example.test/rss", title: "A show"})
      {:ok, _other} = Playback.set_favourite(other)

      assert [found] = InternetRadio.roots() |> named("Favourites") |> read()
      assert found.id == marked.id
    end

    test "Countries and Tags read the facets, and each one is a facet listing" do
      Stations.create(%{country_code: "NZ", tags: ["news"]})

      assert {_name, %{kind: :facet}} = InternetRadio.roots() |> named("Countries")

      assert ["NZ"] =
               InternetRadio.roots() |> named("Countries") |> read() |> Enum.map(& &1.value.value)

      assert ["news"] =
               InternetRadio.roots() |> named("Tags") |> read() |> Enum.map(& &1.value.value)
    end
  end

  describe "podcasts" do
    test "Subscriptions reads the shows that a person marked" do
      show = PodcastFill.show(%{feed_url: "https://example.test/rss", title: "Road Work"})
      PodcastFill.show(%{feed_url: "https://other.test/rss", title: "Not subscribed"})
      {:ok, _show} = Playback.set_favourite(show)

      assert [found] = Podcasts.roots() |> named("Subscriptions") |> read()
      assert found.title == "Road Work"
    end

    # An episode is a track of the show, and Subscriptions lists the shows alone.
    test "Subscriptions gives no episode" do
      show = PodcastFill.show(%{feed_url: "https://example.test/rss", title: "Road Work"})
      {:ok, show} = Playback.set_favourite(show)

      PodcastFill.episodes(show, "https://example.test/rss", [
        %{
          guid: "one",
          title: "An episode",
          audio_url: "https://example.test/1.mp3",
          mime_type: "audio/mpeg",
          duration_ms: 600_000,
          published_at: ~U[2022-06-02 14:00:00.000000Z],
          description: nil,
          artwork_url: nil
        }
      ])

      assert [%{kind: :container}] = Podcasts.roots() |> named("Subscriptions") |> read()
    end
  end

  # Below a root the tree needs no source. A facet row opens into the items that link
  # to it, and a container opens into its children.
  test "every root names a query and says what it reads" do
    for source <- [InternetRadio, Podcasts], {name, listing} <- source.roots() do
      assert is_binary(name)
      assert listing.kind in [:item, :facet]
      assert %Ash.Query{} = listing.query
    end
  end
end
