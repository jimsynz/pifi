defmodule MyHiFi.Radio.CarryFavourites do
  @moduledoc """
  Keep the stations that a person marked, when the catalogue takes over from `Station`.

  `MyHiFi.Source.InternetRadio` reads `MyHiFi.Playback.Item` now, and a device rebuilds
  that table from Radio Browser. A mark is not the data of the service, so a rebuild
  must not lose it.

  This writes one item for each marked station, with the identity that
  `MyHiFi.Radio.Fill` uses: the name of the source, and the identifier of the station
  at the service. The next sync fills in the title, the address and the rest, and it
  leaves the mark alone, because the `upsert` of an item accepts nothing that belongs
  to a person.

  A migration calls this, and it lives here and not in the migration so that a test can
  call it too. It writes plain SQL, because `Station` is going and a migration must not
  depend on a resource that a later release removes.

  **The column list must name every column that takes no null.** A migration runs
  against the schema of its own moment, and this module runs against the schema of
  today, so a new column of `playback_items` that takes no null must arrive in the
  migration that makes the table, and here.
  """

  @doc """
  Write an item for each marked station, and give the number that came across.

  It returns 0 when the device has no `stations` table. A later release removes
  that table, and a device that is built from nothing never had one, so this must not
  stop either of them.
  """
  @spec run(module()) :: non_neg_integer()
  def run(repo) do
    if stations_table?(repo), do: carry(repo), else: 0
  end

  defp stations_table?(repo) do
    %{rows: rows} =
      repo.query!(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'stations'",
        [],
        log: false
      )

    rows != []
  end

  defp carry(repo) do
    marked =
      repo.query!(
        """
        SELECT remote_id, title, last_played_at
        FROM stations
        WHERE favourite = 1 AND remote_id IS NOT NULL AND remote_id != ''
        """,
        [],
        log: false
      )

    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Enum.each(marked.rows, fn [remote_id, title, last_played_at] ->
      repo.query!(
        """
        INSERT INTO playback_items
          (id, source, source_ref, kind, title, favourite, live, played, keeps_place,
           position_ms, rank, container_format, last_played_at, inserted_at, updated_at)
        VALUES (?, 'internet-radio', ?, 'track', ?, 1, 1, 0, 0, 0, 0, 'none', ?, ?, ?)
        ON CONFLICT (source, source_ref) DO UPDATE SET favourite = 1
        """,
        [Ecto.UUID.generate(), remote_id, title || "A station", last_played_at, now, now],
        log: false
      )
    end)

    length(marked.rows)
  end
end
