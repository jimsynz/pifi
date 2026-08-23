defmodule MyHiFi.Podcast.EpisodeTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Podcast

  setup do
    show =
      Podcast.upsert_show_from_feed!(%{
        feed_url: "https://example.test/rss",
        title: "Road Work"
      })

    {:ok, show: show}
  end

  defp from_feed(show, overrides \\ %{}) do
    defaults = %{
      show_id: show.id,
      guid: "episode-#{System.unique_integer([:positive])}",
      title: "257: Emotional Facts",
      subtitle: "A subtitle.",
      description: "A description.",
      audio_url: "https://example.test/257.mp3",
      mime_type: "audio/mpeg",
      byte_length: 46_739_203,
      duration_ms: 2_921_000,
      published_at: ~U[2022-06-02 19:00:00Z],
      artwork_url: "https://example.test/episode.jpg"
    }

    Podcast.upsert_episode_from_feed!(Map.merge(defaults, overrides))
  end

  describe "upsert_from_feed" do
    test "it writes an episode", %{show: show} do
      episode = from_feed(show)

      assert episode.show_id == show.id
      assert episode.title == "257: Emotional Facts"
      assert episode.duration_ms == 2_921_000
      # The attribute holds microseconds, and a `<pubDate>` holds whole seconds.
      assert DateTime.compare(episode.published_at, ~U[2022-06-02 19:00:00Z]) == :eq
      assert episode.position_ms == 0
      assert episode.played? == false
    end

    test "a second read updates the row of the first one", %{show: show} do
      first = from_feed(show, %{guid: "one", title: "Old title"})
      second = from_feed(show, %{guid: "one", title: "New title"})

      assert second.id == first.id
      assert second.title == "New title"
      assert length(Podcast.episodes_of_show!(show.id)) == 1
    end

    test "it leaves the place of the person alone", %{show: show} do
      episode = from_feed(show, %{guid: "one"})
      {:ok, _episode} = Podcast.store_position(episode, %{position_ms: 90_000})

      updated = from_feed(show, %{guid: "one", title: "New title"})

      assert updated.position_ms == 90_000
      assert updated.title == "New title"
    end

    test "an episode with no audio cannot be written", %{show: show} do
      assert {:error, _reason} =
               Podcast.upsert_episode_from_feed(%{
                 show_id: show.id,
                 guid: "one",
                 audio_url: nil
               })
    end

    test "the same guid in two shows gives two episodes", %{show: show} do
      other =
        Podcast.upsert_show_from_feed!(%{
          feed_url: "https://example.test/other/rss",
          title: "Another show"
        })

      first = from_feed(show, %{guid: "shared"})
      second = from_feed(other, %{guid: "shared"})

      refute first.id == second.id
    end
  end

  describe "by_show" do
    test "it reads the episodes of one show, the newest one first", %{show: show} do
      from_feed(show, %{guid: "old", published_at: ~U[2020-01-01 00:00:00Z]})
      from_feed(show, %{guid: "new", published_at: ~U[2026-08-22 00:00:00Z]})
      from_feed(show, %{guid: "middle", published_at: ~U[2023-05-05 00:00:00Z]})

      assert Enum.map(Podcast.episodes_of_show!(show.id), & &1.guid) == ["new", "middle", "old"]
    end

    test "it reads no episode of another show", %{show: show} do
      other =
        Podcast.upsert_show_from_feed!(%{
          feed_url: "https://example.test/other/rss",
          title: "Another show"
        })

      from_feed(show, %{guid: "ours"})
      from_feed(other, %{guid: "theirs"})

      assert Enum.map(Podcast.episodes_of_show!(show.id), & &1.guid) == ["ours"]
    end
  end

  describe "the place inside an episode" do
    test "`store_position` writes where the person stopped", %{show: show} do
      episode = from_feed(show)

      {:ok, episode} = Podcast.store_position(episode, %{position_ms: 125_000})

      assert episode.position_ms == 125_000
    end

    test "`mark_played` marks the episode and returns the place to the start", %{show: show} do
      episode = from_feed(show)
      {:ok, episode} = Podcast.store_position(episode, %{position_ms: 2_900_000})

      {:ok, episode} = Podcast.mark_played(episode)

      assert episode.played? == true
      assert episode.position_ms == 0
    end
  end

  describe "the show of an episode" do
    test "an episode needs a show" do
      assert {:error, _reason} =
               Podcast.upsert_episode_from_feed(%{
                 guid: "one",
                 audio_url: "https://example.test/1.mp3"
               })
    end

    test "a show loads its episodes", %{show: show} do
      from_feed(show, %{guid: "one"})
      from_feed(show, %{guid: "two"})

      assert {:ok, show} = Podcast.get_show(show.id, load: [:episodes])
      assert length(show.episodes) == 2
    end
  end

  describe "destroy" do
    test "it removes one episode and it leaves the others", %{show: show} do
      keep = from_feed(show, %{guid: "keep"})
      drop = from_feed(show, %{guid: "drop"})

      assert :ok = Podcast.destroy_episode(drop)

      assert Enum.map(Podcast.episodes_of_show!(show.id), & &1.id) == [keep.id]
    end

    test "a show that still holds an episode cannot be removed", %{show: show} do
      from_feed(show, %{guid: "one"})

      # SQLite holds the foreign key, so the episodes go first. The refresh job and
      # the source both need to know this.
      assert {:error, _reason} = Podcast.destroy_show(show)
    end

    test "a show with no episode can be removed", %{show: show} do
      episode = from_feed(show, %{guid: "one"})

      assert :ok = Podcast.destroy_episode(episode)
      assert :ok = Podcast.destroy_show(show)
    end
  end
end
