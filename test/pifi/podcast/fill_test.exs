defmodule PiFi.Podcast.FillTest do
  use PiFi.DataCase, async: false
  use Oban.Testing, repo: PiFi.Repo

  alias PiFi.Playback
  alias PiFi.Playback.Item
  alias PiFi.Podcast.Fill

  @feed "https://example.test/rss"

  defp show(overrides \\ %{}) do
    Fill.show(
      Map.merge(
        %{
          feed_url: @feed,
          title: "Road Work",
          description: "A show about work.",
          artwork_url: "https://example.test/cover.jpg"
        },
        overrides
      )
    )
  end

  defp episode(overrides \\ %{}) do
    Map.merge(
      %{
        guid: "episode-#{System.unique_integer([:positive])}",
        title: "An episode",
        description: "What it holds.",
        audio_url: "https://example.test/1.mp3",
        mime_type: "audio/mpeg",
        duration_ms: 2_921_000,
        published_at: ~U[2022-06-02 14:00:00.000000Z],
        artwork_url: nil
      },
      overrides
    )
  end

  describe "a show" do
    test "it becomes a container, and the feed address names it" do
      item = show()

      assert item.kind == :container
      assert item.source == "podcasts"
      assert item.source_ref == @feed
      assert item.title == "Road Work"
      assert item.description == "A show about work."
      assert item.artwork_url == "https://example.test/cover.jpg"
      # A container plays nothing.
      assert item.url == nil
    end

    test "a second read updates the row and writes no second one" do
      show(%{title: "First"})
      show(%{title: "Second"})

      assert [item] = Playback.items_of_source!("podcasts")
      assert item.title == "Second"
    end

    # A subscription belongs to the person, and the publisher knows nothing of it.
    test "a second read leaves a subscription alone" do
      item = show()
      {:ok, _marked} = Playback.set_favourite(item)

      show(%{title: "A new title"})

      assert {:ok, read} = Playback.get_item(item.id)
      assert read.title == "A new title"
      assert read.favourite? == true
    end
  end

  # **A list of shows draws the cover of each one, and nothing else asks for it.** A
  # page builds the address of a picture and reads nothing, so the read of the index or
  # of the feed is what asks. See `PiFi.Artwork.ensure/1`.
  describe "the cover of a show" do
    test "it asks for the cover that the show names" do
      show(%{artwork_url: "https://example.test/cover.jpg"})

      assert_enqueued(
        worker: PiFi.Artwork.Worker,
        args: %{"urls" => ["https://example.test/cover.jpg"]}
      )
    end

    test "a show that names no cover asks for nothing" do
      show(%{artwork_url: nil})

      refute_enqueued(worker: PiFi.Artwork.Worker)
    end
  end

  describe "the episodes of a show" do
    test "each one is a track of that container" do
      item = show()

      assert 2 = Fill.episodes(item, @feed, [episode(%{guid: "a"}), episode(%{guid: "b"})])

      assert [found, _other] = Playback.items_of_parent!(item.id)
      assert found.kind == :track
      assert found.parent_id == item.id
      assert found.transport == :download
      assert found.format == :mp3
      assert found.live? == false
    end

    # A person goes on from where they stopped in an episode, on a later day.
    test "an episode keeps its place" do
      item = show()
      Fill.episodes(item, @feed, [episode()])

      assert [%{keeps_place?: true}] = Playback.items_of_parent!(item.id)
    end

    test "the date and the length become the subtitle" do
      item = show()
      Fill.episodes(item, @feed, [episode()])

      assert [%{subtitle: "2 Jun 2022, 48 min"}] = Playback.items_of_parent!(item.id)
    end

    test "an episode with no date names its length alone" do
      item = show()
      Fill.episodes(item, @feed, [episode(%{published_at: nil})])

      assert [%{subtitle: "48 min"}] = Playback.items_of_parent!(item.id)
    end

    # A `<guid>` is unique inside its feed and not outside it.
    test "two shows can hold one guid" do
      first = show(%{feed_url: "https://one.test/rss"})
      second = show(%{feed_url: "https://two.test/rss"})

      Fill.episodes(first, "https://one.test/rss", [episode(%{guid: "same", title: "One"})])
      Fill.episodes(second, "https://two.test/rss", [episode(%{guid: "same", title: "Two"})])

      assert [%{title: "One"}] = Playback.items_of_parent!(first.id)
      assert [%{title: "Two"}] = Playback.items_of_parent!(second.id)
    end

    test "a type that this firmware cannot play is unknown" do
      item = show()
      Fill.episodes(item, @feed, [episode(%{mime_type: "audio/x-m4a"})])

      assert [%{format: :unknown}] = Playback.items_of_parent!(item.id)
    end

    # This is why a place lives on the item. A feed that a job reads again must not
    # move a person back to the start of what they part heard.
    test "a second read keeps the place and the played mark" do
      item = show()
      Fill.episodes(item, @feed, [episode(%{guid: "one", title: "An old title"})])
      [written] = Playback.items_of_parent!(item.id)

      {:ok, _placed} =
        Playback.store_position(written, %{position_ms: 90_000, position_bytes: 1_440_000})

      Fill.episodes(item, @feed, [episode(%{guid: "one", title: "A new title"})])

      assert {:ok, read} = Playback.get_item(written.id)
      assert read.title == "A new title"
      assert read.position_ms == 90_000
      assert read.position_bytes == 1_440_000
    end

    test "an empty feed writes nothing" do
      item = show()

      assert 0 = Fill.episodes(item, @feed, [])
      assert Playback.items_of_parent!(item.id) == []
    end

    # The cover of the show serves an episode that holds none. One rule of `Item`
    # serves every source.
    test "an episode with no picture uses the cover of the show" do
      item = show()
      Fill.episodes(item, @feed, [episode()])

      assert [bare] = Playback.items_of_parent!(item.id)
      assert {:ok, read} = Playback.get_item(bare.id, load: [:artwork])
      assert read.artwork == "https://example.test/cover.jpg"
    end
  end

  test "a show and its episodes are one source" do
    item = show()
    Fill.episodes(item, @feed, [episode()])

    assert Ash.count!(Item) == 2
    assert length(Playback.items_of_source!("podcasts")) == 2
  end
end
