defmodule PiFi.Test.QueryPlan do
  @moduledoc """
  What SQLite says that it will do with the statement that Ash writes.

  **An index of a column serves no comparison of an expression.** Ash compares a column
  of `Ash.Type.Atom`, of `Ash.Type.UUID` and of a boolean as a cast, so
  `CAST(id AS TEXT) = CAST(? AS TEXT)` reads the whole table where `id = ?` reads one
  row. A statement by hand holds no cast, it uses the index, and it says nothing about
  what the firmware does, so these helpers read the statement that Ash writes.

  See the `custom_statements` of `PiFi.Playback.Item` and the `custom_indexes` of
  `PiFi.Cache.Entry`.
  """

  import ExUnit.Assertions

  @doc """
  The plan of the read of one query, over the table that the caller names.
  """
  @spec of(Ash.Query.t(), String.t()) :: String.t()
  def of(query, table) do
    while(table, fn -> Ash.read!(query, page: [limit: 25, count: false], authorize?: false) end)
  end

  @doc """
  The plan of the statement that one function makes, over the table that the caller
  names.

  A caller that reads through `Ash.load!/2` or through a function of a domain gives
  that call here, because the statement of such a read is the one that matters.
  """
  @spec while(String.t(), (-> term()), (String.t() -> boolean())) :: String.t()
  def while(table, fun, wanted? \\ fn _sql -> true end) do
    probe = :"query_plan_probe_#{:erlang.unique_integer([:positive])}"
    Process.register(self(), probe)

    handler = "query-plan-#{:erlang.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:pifi, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if metadata[:source] == table and wanted?.(metadata[:query]) do
          send(probe, {:sql, metadata[:query], metadata[:params]})
        end
      end,
      nil
    )

    try do
      fun.()
      plan_of(table)
    after
      :telemetry.detach(handler)
      Process.unregister(probe)
    end
  end

  # **A temporary tree over the last term alone is correct.** Ash orders by `id` after
  # the sort of the caller, so that a page of a keyset is stable, and that term orders
  # the rows of one title. A tree over the whole order is the fault that these tests are
  # about.
  @doc """
  Refuses a plan that puts every row of the read in order.
  """
  @spec refute_full_sort(String.t()) :: boolean()
  def refute_full_sort(plan) do
    refute plan =~ "USE TEMP B-TREE FOR ORDER BY"
  end

  @doc """
  Refuses a plan that reads every row of the table.
  """
  @spec refute_scan(String.t()) :: boolean()
  def refute_scan(plan) do
    refute plan =~ "SCAN"
  end

  defp plan_of(table) do
    receive do
      {:sql, sql, params} ->
        {:ok, %{rows: rows}} = PiFi.Repo.query("EXPLAIN QUERY PLAN " <> sql, params)

        Enum.map_join(rows, " | ", &List.last/1)
    after
      1000 -> flunk("No statement of `#{table}` reached the telemetry event.")
    end
  end
end
