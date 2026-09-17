defmodule PiFi.Radio.CarryFavouritesTest do
  use PiFi.DataCase, async: false

  alias PiFi.Playback
  alias PiFi.Radio.CarryFavourites
  alias PiFi.Radio.Fill

  # `PiFi.Radio.Station` is gone and a migration drops its table, so this makes the
  # shape that an upgrading device holds. The carry reads three columns of it, and the
  # test owns the fixture that it needs.
  setup do
    PiFi.Repo.query!(
      """
      CREATE TABLE stations (
        id TEXT PRIMARY KEY,
        remote_id TEXT,
        title TEXT,
        favourite BOOLEAN NOT NULL DEFAULT 0,
        last_played_at TEXT
      )
      """,
      [],
      log: false
    )

    :ok
  end

  defp station(overrides) do
    attributes =
      Map.merge(%{remote_id: "remote-1", title: "RNZ National", favourite: 1}, overrides)

    PiFi.Repo.query!(
      "INSERT INTO stations (id, remote_id, title, favourite) VALUES (?, ?, ?, ?)",
      [
        Ecto.UUID.generate(),
        attributes.remote_id,
        attributes.title,
        attributes.favourite
      ],
      log: false
    )

    attributes
  end

  defp from_service(remote_id, overrides \\ %{}) do
    Fill.stations([
      Map.merge(
        %{
          remote_id: remote_id,
          title: "The title of the service",
          stream_url: "http://example.test/stream.mp3",
          codec: "MP3",
          bitrate: 128,
          hls?: false,
          country_code: "NZ",
          language: nil,
          tags: ["news"],
          artwork_url: nil,
          click_count: 7
        },
        overrides
      )
    ])
  end

  test "a marked station becomes a marked item" do
    station(%{remote_id: "kept", title: "RNZ Concert"})
    station(%{remote_id: "not-kept", favourite: 0})

    assert CarryFavourites.run(PiFi.Repo) == 1

    assert [item] = Playback.favourite_items!()
    assert item.source == "internet-radio"
    assert item.source_ref == "kept"
    assert item.title == "RNZ Concert"
  end

  test "it carries nothing when no station is marked" do
    station(%{favourite: 0})

    assert CarryFavourites.run(PiFi.Repo) == 0
    assert Playback.favourite_items!() == []
  end

  # This is the whole point. A device rebuilds the catalogue from Radio Browser, and
  # the mark must live through that.
  test "the next fill writes the real fields and keeps the mark" do
    station(%{remote_id: "kept", title: "An old title"})

    CarryFavourites.run(PiFi.Repo)
    from_service("kept", %{title: "The title of the service"})

    assert [item] = Playback.favourite_items!()
    assert item.title == "The title of the service"
    assert item.url == "http://example.test/stream.mp3"
    assert item.rank == 7
    assert item.favourite? == true
  end

  # A device that ran the fill before the migration already holds the item.
  test "a station that the fill already wrote takes the mark" do
    station(%{remote_id: "kept"})
    from_service("kept")

    assert Playback.favourite_items!() == []

    assert CarryFavourites.run(PiFi.Repo) == 1

    assert [item] = Playback.favourite_items!()
    assert item.source_ref == "kept"
    assert item.title == "The title of the service"
    assert Ash.count!(PiFi.Playback.Item) == 1
  end

  test "a station with no identifier at the service is left alone" do
    station(%{remote_id: "has-one"})
    station(%{remote_id: ""})

    assert CarryFavourites.run(PiFi.Repo) == 1
  end

  # A device that has run this before holds no such table, and a device that is built
  # from nothing never had one.
  test "a device with no old table carries nothing" do
    PiFi.Repo.query!("DROP TABLE stations", [], log: false)

    assert CarryFavourites.run(PiFi.Repo) == 0
  end
end
