defmodule PiFi.Cache.Touches do
  @moduledoc """
  The used marks of the cache, held in memory and written together.

  The eviction of `PiFi.Cache` takes the entry that something used least recently,
  so each read of an entry must say that it happened. **A row for each read is what
  that costs, and a page of the web interface reads 25 of them.** One request of
  `/artwork/<hash>/thumbnail` wrote one row, so opening one list wrote 25 rows in 25
  transactions, each one asking the card for the write lock. A measurement on
  2026-09-07 found the answer to that on a device: `Exqlite.Error: Database busy`,
  raised in `Oban.Pruner` and in `PiFi.Cache.Entry.put_file`, which threw away a
  podcast episode that had already arrived.

  This process keeps the marks instead. It writes them in one statement, so 25
  acquisitions of the write lock become one, and a card that this firmware must run on
  for years takes 25 times fewer writes for the same browsing.

  ## What a flush loses, and why that is correct

  **Nothing that any caller can read.** The three callers of `PiFi.Cache.used/1`
  ignore what it answers, and the one reader of `last_accessed_at` is the eviction,
  which `PiFi.Cache` describes as least recently used and approximate. An
  interruption of the power therefore loses marks and no data.

  Every entry of one flush takes the same time as well. A least recently used order
  needs no finer detail than "these were used in the same second", and one value for
  the whole batch is what makes the flush one statement.

  ## The timeout of a GenServer, and the ceiling over it

  `handle_info/2` answers `{:noreply, state, timeout}`, so the process wakes itself
  when nothing arrives for that long. That is the debounce, and it is 1 second.

  **A debounce alone can wait for ever.** The timeout starts again with each message,
  so a person who browses a library without a pause would let nothing reach the card
  for as long as they browse. The ceiling bounds that: the wait is the debounce, or
  what is left of the ceiling, whichever is less. `PiFi.SwitchOff` uses the same
  shape, with a checkpoint on a period for the power that goes without warning.

  ## Who flushes, and when

  - The debounce and the ceiling, above.
  - `c:GenServer.terminate/2`, so a restart of the firmware keeps what it knew. That
    callback needs `Process.flag(:trap_exit, true)`, or a supervisor that shuts the
    process down kills it first.
  - `PiFi.SwitchOff.prepare/1`, before it folds the log into the database. A device
    that says that a hand may reach the switch must hold nothing in memory.
  - `PiFi.Cache.Entry.Prune`, because the eviction is the one reader of these marks.
    A prune that read a stale row could take the entry whose picture is on a screen.

  **A firmware that runs no buffer writes at once.** `PiFi.Cache.used/1` reads
  `Process.whereis/1` and writes the row itself when this process is absent, so the
  test environment needs no buffer and no flush. See `PiFi.Application`.
  """

  use GenServer

  require Ash.Query
  require Logger

  alias PiFi.Cache

  @debounce_ms 1_000
  @ceiling_ms :timer.minutes(1)

  @doc """
  Start the buffer.

  `debounce_ms` is how long the process waits for another mark, and `ceiling_ms` is
  the longest that a mark may wait whatever else arrives.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Note that something used one entry, and write nothing now.

  It returns `:none` when no buffer runs, and `PiFi.Cache.used/1` then writes the row
  itself.
  """
  @spec record(Ash.UUID.t()) :: :ok | :none
  def record(id) do
    case Process.whereis(__MODULE__) do
      nil ->
        :none

      pid ->
        send(pid, {:touch, id})
        :ok
    end
  end

  @doc """
  Write what the buffer keeps, and wait for the answer.

  A caller that must read `last_accessed_at` calls this first. It returns `:ok` when no
  buffer runs, because there is then nothing to wait for.
  """
  @spec flush() :: :ok
  def flush do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, :flush)
    end
  end

  @doc false
  @impl GenServer
  def init(opts) do
    # **`c:GenServer.terminate/2` runs for a shutdown only when the process traps
    # exits.** Without this the supervisor kills the process and the marks of the last
    # second go, which is what a test of the stop measured.
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       buffer: [],
       since: nil,
       debounce_ms: Keyword.get(opts, :debounce_ms, @debounce_ms),
       ceiling_ms: Keyword.get(opts, :ceiling_ms, @ceiling_ms)
     }}
  end

  @doc false
  @impl GenServer
  def handle_info({:touch, id}, state) do
    state = %{state | buffer: [id | state.buffer], since: state.since || now_ms()}

    {:noreply, state, wait(state)}
  end

  def handle_info(:timeout, state), do: {:noreply, write(state)}

  @doc false
  @impl GenServer
  def handle_call(:flush, _from, state), do: {:reply, :ok, write(state)}

  @doc false
  @impl GenServer
  def terminate(_reason, state) do
    write(state)

    :ok
  end

  defp wait(state) do
    left = state.ceiling_ms - (now_ms() - state.since)

    state.debounce_ms |> min(left) |> max(0)
  end

  defp write(%{buffer: []} = state), do: state

  defp write(state) do
    ids = Enum.uniq(state.buffer)

    # **A flush that fails says so.** The write lock of the card is what this process
    # exists to ask for less often, and a busy database is the fault that it answers. A
    # flush that went quiet would hide the one measurement that matters.
    case Cache.Entry |> Ash.Query.filter(id in ^ids) |> Cache.touch_all() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("#{length(ids)} used marks did not write: #{inspect(reason)}")
    end

    %{state | buffer: [], since: nil}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
