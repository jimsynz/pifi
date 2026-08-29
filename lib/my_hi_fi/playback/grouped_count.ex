defmodule MyHiFi.Playback.GroupedCount do
  @moduledoc """
  How many rows of one table point at each record of a page.

  `MyHiFi.Playback.Facet` uses it to say how many items hold a facet, and
  `MyHiFi.Playback.Item` uses it to say how many children a container holds. A person
  reads that number beside the name, and it tells them whether the row is worth opening.

  ## Why this holds SQL, and why it is the one place that does

  AshSqlite expresses no aggregate of any kind. `can?(_, {:aggregate, _type})` gives
  `false`, so `count`, `first` and the rest report "is not aggregatable" for every shape
  of relationship. A query aggregate works, and `Ash.count/1` is one, but it counts one
  record at a time.

  A page holds 100 rows. A measurement on 2026-08-26 gave 77 ms for 100 calls of
  `Ash.count!/1` on a laptop, and 2 ms for one query with `GROUP BY`. This board is
  about 10 times slower than that laptop, and Cinder reads the query again for each
  press of a control. One second for each render is too slow, and 30 ms is not.

  **Do not copy this module.** Reach for it, or for `Ash.count/1`. A new place that
  writes SQL by hand is a new place that the data layer cannot check.

  ## How it batches

  Ash gives every record of the page to `calculate/3` in one call, so a page of 100 rows
  costs one query. `MyHiFiWeb.BrowseLive` loads it with `query_opts`, and Cinder keeps
  what that names.

  ## The index matters

  A count reads one column of one table, and it reads nothing else. Each table that
  this module counts therefore needs an index on that column. Without one, SQLite reads
  the whole table for each render.
  """

  use Ash.Resource.Calculation

  alias Ecto.Adapters.SQL

  # SQLite accepts a limited number of values in one statement, and an old build stops
  # at 999.
  @chunk 500

  @impl true
  def init(opts) do
    with {:ok, table} <- name(opts[:table], :table),
         {:ok, column} <- name(opts[:column], :column) do
      {:ok, table: table, column: column}
    end
  end

  @impl true
  def calculate(records, opts, _context) do
    counts =
      records
      |> Enum.map(& &1.id)
      |> counts(opts)

    Enum.map(records, &Map.get(counts, &1.id, 0))
  end

  defp counts([], _opts), do: %{}

  defp counts(ids, opts) do
    ids
    |> Enum.chunk_every(@chunk)
    |> Enum.reduce(%{}, fn chunk, found -> Map.merge(found, chunk_counts(chunk, opts)) end)
  end

  # Sobelow reads the interpolation and reports SQL injection. The identifiers come from
  # the resource, and `init/1` accepts a plain name and nothing else. Each value goes in
  # as a parameter, so no value of the database reaches the statement as text.
  # sobelow_skip ["SQL.Query"]
  defp chunk_counts(ids, opts) do
    column = opts[:column]
    places = Enum.map_join(ids, ",", fn _id -> "?" end)

    statement = """
    SELECT #{column}, count(*) FROM #{opts[:table]} \
    WHERE #{column} IN (#{places}) GROUP BY #{column}\
    """

    %{rows: rows} = SQL.query!(MyHiFi.Repo, statement, ids)

    Map.new(rows, fn [id, count] -> {id, count} end)
  end

  # The names come from the resource and never from a person. This check is what keeps
  # that true, because the names reach the statement as text.
  defp name(given, part) when is_binary(given) do
    if Regex.match?(~r/^[a-z_][a-z0-9_]*$/, given) do
      {:ok, given}
    else
      {:error, "#{part} of MyHiFi.Playback.GroupedCount is not a plain name: #{inspect(given)}"}
    end
  end

  defp name(given, part) do
    {:error,
     "#{part} of MyHiFi.Playback.GroupedCount must be a string, and it is #{inspect(given)}"}
  end
end
