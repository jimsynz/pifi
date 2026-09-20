defmodule PiFi.Device.Upgrade.Server do
  @moduledoc """
  Holds what this device knows about the newest firmware, and runs an upgrade.

  **The forge is asked on a schedule and not on a render.** `PiFi.Device.Upgrade.Check`
  runs once a day, and a person can ask now. This process keeps the answer, so the
  settings page draws it with no request of its own, and every open page learns of a new
  version through `PiFi.Event.Device.UpgradeChanged`. That is the rule that
  `PiFi.Device.Monitor` follows for the network and the storage.

  ## The work runs in a task, and the state process answers

  An upgrade reads 30 MB and then writes a partition, and this process must answer a
  page while that happens. It therefore spawns a task and holds the progress of it. A
  task that dies leaves the state at `:failed` with the reason, because a person who
  pressed install is owed an answer either way.

  **One upgrade at a time.** A second press while one runs is a press that a person made
  because the first gave them no feedback yet, and starting two writes of the same
  partition is the worst answer to that.

  ## A device that is up to date says so

  `available` is `nil` when the forge names nothing newer, and the page draws the
  version that is running. A comparison of versions and not of strings, so a device
  that a person put a later build on by hand is not told to go backwards.
  """

  use GenServer

  require Logger

  alias PiFi.Device.Upgrade
  alias PiFi.Device.Upgrade.Forge
  alias PiFi.Device.Upgrade.Install
  alias PiFi.Event
  alias PiFi.Event.Device.UpgradeChanged

  defstruct available: nil,
            checked_at: nil,
            notes: "",
            percent: 0,
            reason: nil,
            state: :idle,
            task: nil

  @doc """
  What this device knows about the newest firmware.

  It answers `PiFi.Device.Upgrade` and it never waits for the network: a check that is
  running leaves the last answer in place until it finishes.
  """
  @spec report() :: map()
  def report, do: GenServer.call(__MODULE__, :report)

  @doc """
  Ask the forge now, and report what it said.

  `PiFi.Device.Upgrade.Check` calls this on its schedule, and a person calls it from the
  settings page.
  """
  @spec check() :: {:ok, map()} | {:error, term()}
  def check, do: GenServer.call(__MODULE__, :check, :timer.seconds(30))

  @doc """
  Start the upgrade to the version that the last check named.

  It returns `{:error, :nothing_to_install}` for a device that is up to date, and
  `{:error, :already_running}` for a second press.
  """
  @spec install() :: :ok | {:error, term()}
  def install, do: GenServer.call(__MODULE__, :install)

  @doc false
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @doc false
  @impl GenServer
  def init(_options), do: {:ok, %__MODULE__{}}

  @doc false
  @impl GenServer
  def handle_call(:report, _from, %__MODULE__{} = state), do: {:reply, reported(state), state}

  def handle_call(:check, _from, %__MODULE__{} = state) do
    case Forge.latest() do
      {:ok, release} ->
        state = announced(%__MODULE__{state | checked_at: DateTime.utc_now()}, release)

        {:reply, {:ok, reported(state)}, state}

      {:error, reason} ->
        Logger.info("The forge did not name a release: #{inspect(reason)}")

        {:reply, {:error, reason}, %__MODULE__{state | checked_at: DateTime.utc_now()}}
    end
  end

  def handle_call(:install, _from, %__MODULE__{task: task} = state) when not is_nil(task) do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call(:install, _from, %__MODULE__{available: nil} = state) do
    {:reply, {:error, :nothing_to_install}, state}
  end

  def handle_call(:install, _from, %__MODULE__{} = state) do
    {:reply, :ok, started(state)}
  end

  @doc false
  @impl GenServer
  def handle_info({ref, result}, %__MODULE__{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    {:noreply, finished(%__MODULE__{state | task: nil}, result)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %__MODULE__{task: %Task{ref: ref}} = state
      ) do
    {:noreply, finished(%__MODULE__{state | task: nil}, {:error, reason})}
  end

  def handle_info({:percent, percent}, %__MODULE__{} = state) do
    {:noreply, published(%__MODULE__{state | percent: percent})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A release that is not newer than what runs is no upgrade, and a device that took a
  # later build by hand must not be told to go back to the tag of the forge.
  defp announced(%__MODULE__{} = state, release) do
    if Version.compare(release.version, Upgrade.running_version()) == :gt do
      published(%__MODULE__{state | available: release, notes: release.notes})
    else
      published(%__MODULE__{state | available: nil, notes: ""})
    end
  end

  defp started(%__MODULE__{available: release} = state) do
    server = self()
    progress = fn percent -> send(server, {:percent, percent}) end

    task =
      Task.Supervisor.async_nolink(PiFi.Device.Upgrade.Tasks, fn ->
        Install.run(release, progress)
      end)

    published(%__MODULE__{state | task: task, state: :installing, percent: 0, reason: nil})
  end

  # **The device reboots on success, so `:installed` is a state that a page reads for a
  # moment.** It is worth publishing: a person watching the bar sees the work finish
  # rather than the page going quiet while the board goes down.
  defp finished(%__MODULE__{} = state, :ok),
    do: published(%__MODULE__{state | state: :installed, percent: 100})

  defp finished(%__MODULE__{} = state, {:error, reason}) do
    Logger.error("The upgrade did not finish: #{inspect(reason)}")

    published(%__MODULE__{state | state: :failed, reason: reason})
  end

  defp finished(state, other), do: finished(state, {:error, other})

  defp published(state) do
    Event.publish(:device, struct(UpgradeChanged, reported(state)))

    state
  end

  defp reported(state) do
    %{
      running: Upgrade.running_version(),
      available: state.available && state.available.version,
      notes: state.notes,
      checked_at: state.checked_at,
      state: state.state,
      percent: state.percent,
      reason: state.reason && inspect(state.reason)
    }
  end
end
