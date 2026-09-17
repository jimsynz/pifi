defmodule PiFi.Settings.Cache do
  @moduledoc """
  Holds the settings of the device in memory.

  **A setting is read many times and written almost never.** A person writes one by
  pressing a control, and the firmware reads them on every path: each navigation of
  the web interface asks `PiFi.Source.enabled?/1` for each source, and the player
  asks the same question in three places. Each of those was a `SELECT` on an SD card.

  `PiFi.Settings` is the one door to this table, so it is the one place that writes
  the memory. It holds the answer for a key that the table has no row for as well,
  because a source that a person never chose is the usual case and it asked the card
  each time.

  A read comes from the calling process, so this process never reads the database.
  The sandbox of Ecto gives the connection of a test to the process of that test, and
  a read of another process would need permission that an async test cannot give.
  `PiFi.Cache.Touches` names the same rule.

  This process owns the table and does nothing else. An ETS table goes when the
  process that made it goes, and the supervisor then starts this one again with an
  empty table, which is correct: the next read fills it from the database.
  """

  use GenServer

  @table :pifi_settings

  @typedoc "What the memory holds for one key, or `:miss` for a key that it does not."
  @type answer :: {:ok, term()} | :miss

  @doc false
  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Remove every answer, so the next read of each key reads the database.

  A test writes rows that a rollback then takes away, and the memory cannot see that
  rollback. `PiFi.DataCase` and `PiFiWeb.ConnCase` therefore call this before
  each test.
  """
  @spec clear() :: :ok
  def clear do
    if ready?(), do: :ets.delete_all_objects(@table)

    :ok
  end

  @doc """
  What the memory holds for one key.
  """
  @spec fetch(String.t()) :: answer()
  def fetch(key) do
    if ready?() do
      case :ets.lookup(@table, key) do
        [{^key, answer}] -> {:ok, answer}
        [] -> :miss
      end
    else
      :miss
    end
  end

  @doc """
  Remove the answer for one key.
  """
  @spec forget(String.t()) :: :ok
  def forget(key) do
    if ready?(), do: :ets.delete(@table, key)

    :ok
  end

  @doc """
  Hold one answer for one key.
  """
  @spec put(String.t(), term()) :: :ok
  def put(key, answer) do
    if ready?(), do: :ets.insert(@table, {key, answer})

    :ok
  end

  @doc false
  @impl GenServer
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    {:ok, nil}
  end

  # A mix task and a release command read a setting with no supervision tree, and each
  # one then reads the database as this module never existed.
  defp ready?, do: :ets.whereis(@table) != :undefined
end
