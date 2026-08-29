defmodule MyHiFi.Podcast.CarryPlaces do
  @moduledoc """
  Keep what a person did with a podcast, when the catalogue takes over.

  A device rebuilds the catalogue from the feed of each publisher, and three things are
  not the data of the publisher:

  - the shows that a person subscribed to,
  - where they stopped in an episode,
  - the episodes that they reached the end of.

  This writes an item for each of those, with the identity that `MyHiFi.Podcast.Fill`
  uses. The next read of the feed fills in the title, the address and the rest, and it
  leaves all three alone, because the `upsert` of an item accepts none of them.

  A migration calls this, and it lives here so that a test can call it too. It writes
  plain SQL, because `Episode` is going and a migration must not depend on a resource
  that a later release removes.

  **The column list must name every column that takes no null.** A migration runs
  against the schema of its own moment, and this module runs against the schema of
  today. See `MyHiFi.Radio.CarryFavourites`, which learnt the same lesson.

  ## The file of an episode that a device already holds goes

  `MyHiFi.Player.Download` keys a file by the identifier of the episode, and an item
  holds a new one. A part heard episode therefore arrives again over the network, and
  the eviction of the cache reclaims the file that no row names. The place of the
  person lives through it, which is the part that matters.
  """

  @doc """
  Write an item for each show and each episode that a person touched.

  It gives the number of shows and the number of episodes that came across.
  """
  @spec run(module()) :: %{shows: non_neg_integer(), episodes: non_neg_integer()}
  def run(repo) do
    if tables?(repo), do: carry(repo), else: %{shows: 0, episodes: 0}
  end

  defp tables?(repo) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT name FROM sqlite_master
        WHERE type = 'table' AND name IN ('podcast_shows', 'podcast_episodes')
        """,
        [],
        log: false
      )

    length(rows) == 2
  end

  defp carry(repo) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %{shows: carry_shows(repo, now), episodes: carry_episodes(repo, now)}
  end

  # A show that a person subscribed to is a container that they marked.
  defp carry_shows(repo, now) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT feed_url, title FROM podcast_shows
        WHERE subscribed = 1 AND feed_url IS NOT NULL AND feed_url != ''
        """,
        [],
        log: false
      )

    Enum.each(rows, fn [feed_url, title] ->
      repo.query!(
        """
        INSERT INTO playback_items
          (id, source, source_ref, kind, title, favourite, live, played, keeps_place,
           position_ms, rank, container_format, inserted_at, updated_at)
        VALUES (?, 'podcasts', ?, 'container', ?, 1, 0, 0, 0, 0, 0, 'none', ?, ?)
        ON CONFLICT (source, source_ref) DO UPDATE SET favourite = 1
        """,
        [Ecto.UUID.generate(), feed_url, title || "A show", now, now],
        log: false
      )
    end)

    length(rows)
  end

  # An episode that a person part heard, or reached the end of. One that they never
  # touched holds nothing worth keeping, and the feed writes it again.
  defp carry_episodes(repo, now) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT s.feed_url, e.guid, e.title, e.position_ms, e.position_bytes, e.played
        FROM podcast_episodes e
        JOIN podcast_shows s ON s.id = e.show_id
        WHERE (e.position_ms > 0 OR e.played = 1)
          AND s.feed_url IS NOT NULL AND s.feed_url != ''
          AND e.guid IS NOT NULL AND e.guid != ''
        """,
        [],
        log: false
      )

    Enum.each(rows, fn [feed_url, guid, title, position_ms, position_bytes, played] ->
      repo.query!(
        """
        INSERT INTO playback_items
          (id, source, source_ref, kind, parent_id, title, favourite, live, played,
           keeps_place, position_ms, position_bytes, rank, container_format,
           inserted_at, updated_at)
        VALUES (
          ?, 'podcasts', ?, 'track',
          (SELECT id FROM playback_items WHERE source = 'podcasts' AND source_ref = ?),
          ?, 0, 0, ?, 1, ?, ?, 0, 'none', ?, ?
        )
        ON CONFLICT (source, source_ref) DO UPDATE
          SET position_ms = excluded.position_ms,
              position_bytes = excluded.position_bytes,
              played = excluded.played
        """,
        [
          Ecto.UUID.generate(),
          feed_url <> " " <> guid,
          feed_url,
          title || "An episode",
          played,
          position_ms || 0,
          position_bytes,
          now,
          now
        ],
        log: false
      )
    end)

    length(rows)
  end
end
