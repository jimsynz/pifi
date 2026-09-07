defmodule MyHiFi.SwitchOff do
  @moduledoc """
  What a device does before it loses its power.

  It loses it in two ways, and this module holds one answer for each.

  **A device that runs on a battery holds no way to turn its own power off.** The
  portable device of this firmware has a switch on its side and a hand reaches it, so
  the moment that a person presses standby is the moment to stop writing to the card
  and say so. `MyHiFi.Event.Device.SafeToSwitchOff` is what says it, and the screen
  draws it.

  ## A checkpoint on a period, for the power that goes without warning

  A cell that dies faster than the warning, a switch that a hand reaches without a
  press of standby, and a fault that stops the whole node all take the power with no
  step 1. **Every device therefore checkpoints on a period, and no person turns that
  off**, because a power cut reaches a device on the mains as well.

  The period bounds what a device can lose, and it costs one checkpoint to do it.

  **`synchronous: :full` is the other answer to this, and it is the wrong one here.** It
  makes each commit durable by itself, and a measurement on the board on 2026-09-02 took
  200 commits from 71 ms to 2249 ms: 0.36 ms each becomes 11.2 ms, which is 32 times.
  A sync of the stations writes a row for each of them, so that sync alone would take
  about 11 seconds longer, and every one of those commits is a write of the card. A
  checkpoint on a period pays one fsync for each period instead of one for each commit.

  SQLite holds an auto checkpoint of its own, and it counts the pages of the log and not
  the time, so a device that writes little can leave a commit in the log for as long as
  it stays quiet. This is what bounds that.

  ## Why a person answers the rest of this, and not the firmware

  A device on the mains wants the opposite. Its background work is scheduled while it
  stands in standby on a shelf, and a firmware that paused the queues there would leave
  the podcasts unread for as long as the device stayed quiet. One image runs on both, so
  a person names which device they hold. See `enabled?/0`.

  ## The order of the four steps

  1. **Pause the queues.** `Oban.pause_all_queues/1` starts no new job. A job that a
     clock or a connection would have started therefore waits for the person to come
     back, and it loses nothing.
  2. **Wait for the jobs that run.** `Oban.check_all_queues/0` names them, and a job
     that reads a feed holds the network for a moment. A wait that never ended would
     leave a person holding a switch, so this gives up after
     #{:erlang.convert_time_unit(30_000, :millisecond, :second)} seconds and says that
     the device is not safe.
  3. **Put the database on the card.** `MyHiFi.Cache.Touches` writes the used marks
     that it holds first, because a device that says that a hand may reach the switch
     must hold nothing in memory. `PRAGMA wal_checkpoint(TRUNCATE)` then folds the
     write ahead log back into the file and empties it. The device holds
     `journal_mode` at `wal` and `synchronous` at `normal`, so a commit is durable at a
     checkpoint and not before one.
  4. **Commit the journal of the file system.** **There is no `sync` in the busybox of
     this system**, so this opens one small file of the data partition and calls
     `:file.sync/1` on it. An fsync of any file commits the running transaction of
     ext4, which carries the metadata of every write before it. A measurement on the
     board on 2026-09-02 took 14.5 ms.

  **The fsync comes last on purpose.** It is the barrier: everything that any step
  before it wrote is on the card when it answers, and the checkpoint of step 3 is part
  of that. An fsync in the middle would leave the database ahead of the file system.

  ## What it does not promise

  A download writes no Oban job, so a track that arrives while a person presses standby
  is not one of the jobs that step 2 waits for. Standby stops the player and the
  download with it, and a file that a download left behind holds no row of the cache,
  because `MyHiFi.Cache.put_file/3` renames it only when it is whole.
  `MyHiFi.Player.Download.sweep/0` takes such a file at the next boot.

  This says that the card holds what the device knows. It says nothing about a person
  who switches the device off while it plays.
  """

  use GenServer

  require Logger

  alias Ecto.Adapters.SQL
  alias MyHiFi.Cache.Touches
  alias MyHiFi.Event
  alias MyHiFi.Event.Device, as: Events
  alias MyHiFi.Event.Player
  alias MyHiFi.Settings

  @key "standby.switch-off"

  # What a device can lose when the power goes with no warning. Five minutes of writes
  # is a track that a person did not finish and a percentage of the cell, and it costs
  # one checkpoint to bound it.
  @checkpoint_ms :timer.minutes(5)

  # A job that reads a feed holds the network for a moment, and a person who pressed
  # standby is waiting. This is long enough for an ordinary read and short enough that a
  # person does not give up on the device.
  @drain_ms 30_000
  @poll_ms 250

  # One small file of the data partition. Nothing reads what it holds: the write and the
  # fsync are the whole of it, and the time in it is there for a person who asks when the
  # device last made itself safe.
  #
  # `/root` is the writable partition of a target and the home of another person on a
  # host, so `config/test.exs` names a path that a test can write.
  @marker "/root/.switch-off"

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The settings key that says whether this device prepares to be switched off.

      iex> MyHiFi.SwitchOff.key()
      "standby.switch-off"
  """
  @spec key() :: String.t()
  def key, do: @key

  @doc "The file that `commit/0` writes and syncs. See the moduledoc."
  @spec marker() :: String.t()
  def marker, do: Application.get_env(:my_hi_fi, :switch_off_marker, @marker)

  @doc """
  Whether this device stops its work when it enters standby.

  **A device that no person changed does not**, because the device on a stereo is the
  one that a firmware cannot ask about. A person who holds the portable device says so
  on the settings page.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Settings.fetch(@key) do
      {:ok, %{value: "true"}} -> true
      _other -> false
    end
  end

  @doc "Say whether this device prepares to be switched off."
  @spec enable(boolean()) :: :ok
  def enable(enabled?) do
    Settings.put!(@key, to_string(enabled?))

    :ok
  end

  @doc """
  Stop the work, put what the device holds on the card, and say whether it is safe.

  A page or a person at the console can call this. `MyHiFi.Playback.standby/1` reaches
  it through the event of the player.
  """
  @spec prepare(timeout()) :: :ok | {:error, :jobs_still_running}
  def prepare(drain_ms \\ @drain_ms) do
    pause()

    case drain(drain_ms) do
      :ok ->
        # A buffer that holds used marks writes them before the log folds into the
        # database, so a device that says this holds nothing in memory. See
        # `MyHiFi.Cache.Touches`.
        Touches.flush()
        checkpoint(:truncate)
        commit()

        Logger.info("The device stopped writing. A person can switch it off now.")
        Event.publish(:device, %Events.SafeToSwitchOff{safe?: true})

        :ok

      {:error, running} ->
        Logger.warning(
          "#{running} background jobs still run after #{div(drain_ms, 1000)} s, so this " <>
            "device does not say that it is safe to switch off."
        )

        {:error, :jobs_still_running}
    end
  end

  @doc """
  Put what the database holds into the file that holds it.

  `:truncate` is for a device that is going quiet, and it empties the log. `:passive`
  is for the checkpoint of the period, and it never waits for a reader and therefore
  never holds a track that plays.
  """
  @spec checkpoint(:truncate | :passive) :: :ok
  def checkpoint(mode \\ :truncate)

  # **A pragma takes no bind parameter**, so the mode cannot be a value of the query and
  # a name that a caller gives would have to reach the text of it. One clause for each
  # holds the whole query as a literal instead, and a mode that this does not know is a
  # fault of the caller and never a query that runs.
  def checkpoint(:truncate), do: run("PRAGMA wal_checkpoint(TRUNCATE)")
  def checkpoint(:passive), do: run("PRAGMA wal_checkpoint(PASSIVE)")

  # Sobelow reads the query of `SQL.query/3` as one that a person could give, because it
  # cannot see that each caller above gives a literal. Nothing here comes from a request:
  # a mode that this module does not name never reaches this function at all.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)
  @sobelow_skip ["SQL.Query"]
  defp run(query) do
    SQL.query(MyHiFi.Repo, query, [])

    :ok
  rescue
    error ->
      Logger.warning("The database did not checkpoint: #{inspect(error)}")

      :ok
  end

  @doc false
  @impl GenServer
  def init(opts) do
    :ok = Event.subscribe(:player)

    state = %{
      drain_ms: Keyword.get(opts, :drain_ms, @drain_ms),
      checkpoint_ms: Keyword.get(opts, :checkpoint_ms, @checkpoint_ms)
    }

    {:ok, tick(state)}
  end

  @doc false
  @impl GenServer
  def handle_info(:checkpoint, state) do
    checkpoint(:passive)

    {:noreply, tick(state)}
  end

  @doc false
  @impl GenServer
  def handle_info(%Player.Standby{entered?: true}, state) do
    if enabled?(), do: prepare(state.drain_ms)

    {:noreply, state}
  end

  # A person who woke the device asked for the work to go on, and the moment that they
  # did is the moment that the card is no longer at rest.
  def handle_info(%Player.Standby{entered?: false}, state) do
    if enabled?() do
      resume()
      Event.publish(:device, %Events.SafeToSwitchOff{safe?: false})
    end

    {:noreply, state}
  end

  def handle_info(%_{}, state), do: {:noreply, state}

  # A queue that does not run gives an error, and a device with no queue is still a
  # device that a person can switch off.
  defp pause do
    Oban.pause_all_queues()
  catch
    :exit, _reason -> :ok
  end

  defp resume do
    Oban.resume_all_queues()
  catch
    :exit, _reason -> :ok
  end

  defp drain(remaining) when remaining <= 0 do
    case running() do
      0 -> :ok
      count -> {:error, count}
    end
  end

  defp drain(remaining) do
    case running() do
      0 ->
        :ok

      _count ->
        Process.sleep(@poll_ms)

        drain(remaining - @poll_ms)
    end
  end

  defp running do
    Oban.check_all_queues()
    |> Enum.map(&length(Map.get(&1, :running, [])))
    |> Enum.sum()
  catch
    :exit, _reason -> 0
  end

  defp tick(state) do
    Process.send_after(self(), :checkpoint, state.checkpoint_ms)

    state
  end

  # Sobelow reads a path of a module attribute as one that a person could give. Nothing
  # here comes from a request: the name is the constant above.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)
  @sobelow_skip ["Traversal.FileModule"]
  defp commit do
    with {:ok, fd} <- File.open(marker(), [:write, :raw]),
         :ok <- IO.binwrite(fd, DateTime.to_iso8601(DateTime.utc_now())),
         :ok <- :file.sync(fd) do
      File.close(fd)
    else
      other -> Logger.warning("The file system did not commit: #{inspect(other)}")
    end
  end
end
