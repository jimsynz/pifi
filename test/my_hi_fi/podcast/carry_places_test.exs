defmodule MyHiFi.Podcast.CarryPlacesTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Playback
  alias MyHiFi.Podcast.CarryPlaces
  alias MyHiFi.Podcast.Fill

  @feed "https://example.test/rss"

  # A migration removes the episodes and the columns of a show that the item holds now.
  # The carry reads the shape that a device holds before that migration, so this test
  # makes it. The thing under test is "given an old database, do the marks and the
  # places come across".
  setup do
    MyHiFi.Repo.query!(
      "ALTER TABLE podcast_shows ADD COLUMN subscribed BOOLEAN NOT NULL DEFAULT 0",
      [],
      log: false
    )

    MyHiFi.Repo.query!("ALTER TABLE podcast_shows ADD COLUMN title TEXT", [], log: false)

    MyHiFi.Repo.query!(
      """
      CREATE TABLE podcast_episodes (
        id TEXT PRIMARY KEY,
        show_id TEXT NOT NULL,
        guid TEXT,
        title TEXT,
        audio_url TEXT,
        position_ms INTEGER NOT NULL DEFAULT 0,
        position_bytes INTEGER,
        played BOOLEAN NOT NULL DEFAULT 0,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """,
      [],
      log: false
    )

    :ok
  end

  defp show(overrides \\ %{}) do
    attributes = Map.merge(%{feed_url: @feed, title: "Road Work", subscribed: 1}, overrides)

    id = Ecto.UUID.generate()

    MyHiFi.Repo.query!(
      "INSERT INTO podcast_shows (id, feed_url, title, subscribed, inserted_at, updated_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?)",
      [id, attributes.feed_url, attributes.title, attributes.subscribed, now(), now()],
      log: false
    )

    Map.put(attributes, :id, id)
  end

  defp episode(show, overrides) do
    attributes =
      Map.merge(
        %{guid: "one", title: "An episode", position_ms: 0, position_bytes: nil, played: 0},
        overrides
      )

    MyHiFi.Repo.query!(
      "INSERT INTO podcast_episodes " <>
        "(id, show_id, guid, title, audio_url, position_ms, position_bytes, played, " <>
        "inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [
        Ecto.UUID.generate(),
        show.id,
        attributes.guid,
        attributes.title,
        "https://example.test/1.mp3",
        attributes.position_ms,
        attributes.position_bytes,
        attributes.played,
        now(),
        now()
      ],
      log: false
    )

    attributes
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp item(source_ref) do
    Enum.find(Playback.items_of_source!("podcasts"), &(&1.source_ref == source_ref))
  end

  test "a show that a person subscribed to becomes a marked container" do
    show()
    show(%{feed_url: "https://other.test/rss", subscribed: 0})

    assert %{shows: 1} = CarryPlaces.run(MyHiFi.Repo)

    assert [marked] = Playback.favourite_items!()
    assert marked.source_ref == @feed
    assert marked.kind == :container
  end

  test "an episode that a person part heard keeps its place" do
    created = show()
    episode(created, %{guid: "one", position_ms: 90_000, position_bytes: 1_440_000})

    assert %{episodes: 1} = CarryPlaces.run(MyHiFi.Repo)

    found = item(@feed <> " one")
    assert found.position_ms == 90_000
    assert found.position_bytes == 1_440_000
    assert found.keeps_place? == true
    assert found.kind == :track
  end

  test "an episode that reached its end keeps that mark" do
    created = show()
    episode(created, %{guid: "done", played: 1})

    assert %{episodes: 1} = CarryPlaces.run(MyHiFi.Repo)
    assert item(@feed <> " done").played? == true
  end

  # A feed writes it again, and there is nothing of the person to keep.
  test "an episode that a person never touched is left alone" do
    created = show()
    episode(created, %{guid: "untouched"})

    assert %{episodes: 0} = CarryPlaces.run(MyHiFi.Repo)
    assert item(@feed <> " untouched") == nil
  end

  test "an episode names the container that holds it" do
    created = show()
    episode(created, %{guid: "one", position_ms: 5_000})

    CarryPlaces.run(MyHiFi.Repo)

    assert item(@feed <> " one").parent_id == item(@feed).id
  end

  # This is the whole point. A device reads the feed again, and the place lives on.
  test "the next read of the feed writes the real fields and keeps the place" do
    created = show()
    episode(created, %{guid: "one", title: "An old title", position_ms: 90_000})

    CarryPlaces.run(MyHiFi.Repo)

    show_item = Fill.show(%{feed_url: @feed, title: "Road Work"})

    Fill.episodes(show_item, @feed, [
      %{
        guid: "one",
        title: "The title of the feed",
        audio_url: "https://example.test/1.mp3",
        mime_type: "audio/mpeg",
        duration_ms: 600_000,
        published_at: ~U[2022-06-02 14:00:00.000000Z],
        description: nil,
        artwork_url: nil
      }
    ])

    found = item(@feed <> " one")
    assert found.title == "The title of the feed"
    assert found.url == "https://example.test/1.mp3"
    assert found.position_ms == 90_000
  end

  test "a device with no old tables carries nothing" do
    MyHiFi.Repo.query!("DROP TABLE podcast_episodes", [], log: false)

    assert %{shows: 0, episodes: 0} = CarryPlaces.run(MyHiFi.Repo)
  end

  test "it leaves the old tables as they are" do
    created = show()
    episode(created, %{guid: "one", position_ms: 5_000})

    CarryPlaces.run(MyHiFi.Repo)

    assert %{rows: [[1]]} =
             MyHiFi.Repo.query!("SELECT count(*) FROM podcast_episodes", [], log: false)
  end
end
