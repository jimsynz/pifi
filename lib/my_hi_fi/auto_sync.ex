defmodule MyHiFi.AutoSync do
  @moduledoc """
  Runs the work that needs the network, when the network is there and the work is due.

  Reading the station list, the trending podcasts, and the feeds that a person follows
  all need the internet, and all three ran on a schedule of the clock before: 4am on a
  Sunday, 5am each day, and every sixth hour.

  **A clock is the wrong condition, and it fails on a device that runs on a battery.**
  That device is switched off at 4am, so the job never runs at all. It is the wrong
  condition on a device on the mains as well: a station list is due because a week
  passed and the network answers, and never because a clock reads 4.

  This process therefore asks four questions instead: is the source of this job in use,
  does that source hold what it needs, does the network reach the internet, and has the
  period of this job passed since it last ran.

  **The source decides the first two, and a job means nothing without it.** Reading the
  trending list is work for podcasts alone, so a person who turned podcasts off asks for
  none of it, and a device that holds no key of the Podcast Index can reach nothing with
  or without a period. See `MyHiFi.Source.enabled?/1` and `MyHiFi.Source.ready?/1`.

  ## Three moments, and the first one earns its place

  - **At the start**, because the device may hold a connection already.
  - **When the network changes**, which is a device that comes back to a place that it
    knows.
  - **Once each hour**, for a device that holds one connection for a month and
    therefore reports no change at all.

  The first is the one that a reader would leave out, and it is the one that matters
  most. `MyHiFi.Device.Monitor` measured this: VintageNet reports `:internet` about half
  a second after the boot and that process starts about six seconds after it, so 11 of
  14 boots never saw the event. Its `handle_continue(:first_read, ...)` publishes
  nothing either, because the state at the start is not a change. A process that waited
  for `MyHiFi.Event.Device.NetworkChanged` alone would therefore sync on the boots where
  Wi-Fi was slow, and on no others.

  ## The gate is cheap on purpose

  `MyHiFi.Device.Network.Report` holds `signal_percent`, so the report changes whenever
  the strength of the signal moves and `MyHiFi.Device.Monitor` publishes each change.
  `due?/1` therefore reads one setting and compares two times, and it asks the network
  nothing.

  ## The period of each job

  A person sets each one in the section of its own source on the settings page, and 0
  turns that job off. The value stays after a restart, as the period of
  `MyHiFi.AutoStandby` does. See `jobs_for/1`.

  A job that never ran holds no time, and it is due at once. That is what fills the
  catalogue of a new device, and it is why `MyHiFi.Radio.FirstSync` is gone: that module
  put a job in the queue when the catalogue held no station, which is the same answer
  that an unset time gives here.

  **The time is written before the job goes in the queue.** Two events in one moment
  would otherwise put two jobs there, and Oban cannot hold them to one: its SQLite
  engine compares the arguments as JSON, and AshOban always puts `tenant: nil` in them,
  so no trigger job of this firmware is unique.
  """

  use GenServer

  require Logger

  alias MyHiFi.Device
  alias MyHiFi.Event
  alias MyHiFi.Event.Device, as: Events
  alias MyHiFi.Settings
  alias MyHiFi.Source

  # A device that holds one connection for a month reports no change, so this asks again
  # on its own. An hour is far shorter than the shortest period below, so it costs a
  # reader nothing to reason about.
  @tick :timer.hours(1)

  # The longest period is a month. A person who wants no run at all chooses 0.
  @max_hours 744

  # `worker` names the module that `worker_module_name` of the resource names, and
  # `MyHiFi.Application` takes each one out of the crontab that `AshOban.config/2`
  # builds. **The `schedule` block of the resource must stay**, because
  # `AshOban.schedule/2` needs it and a scheduled action takes a cron string that cannot
  # be `false`. A trigger takes `scheduler_cron false` and a scheduled action does not.
  @jobs [
    %{
      key: "radio",
      title: "Internet radio stations",
      description: "The list of stations of each country that you chose.",
      source: MyHiFi.Source.InternetRadio,
      resource: MyHiFi.Radio.Sync,
      action: :sync_from_remote,
      worker: MyHiFi.Radio.Sync.Workers.FromRemote,
      default_hours: 168
    },
    %{
      key: "podcast-trending",
      title: "Trending podcasts",
      description: "The list that the Podcast Index holds. It moves slowly.",
      source: MyHiFi.Source.Podcasts,
      resource: MyHiFi.Podcast.Show,
      action: :read_trending,
      worker: MyHiFi.Podcast.Show.Workers.ReadTrending,
      default_hours: 24
    },
    %{
      key: "podcast-refresh",
      title: "The shows that you follow",
      description: "The episodes of each show that you subscribed to.",
      source: MyHiFi.Source.Podcasts,
      resource: MyHiFi.Podcast.Show,
      action: :refresh_all,
      worker: MyHiFi.Podcast.Show.Workers.RefreshAll,
      default_hours: 6
    }
  ]

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @doc """
  Each job that this process runs, in the order that a person reads.

  The settings page draws this list and holds no knowledge of any job, in the way that
  it draws `MyHiFi.Hardware.profiles/0`.
  """
  @spec jobs() :: [map()]
  def jobs, do: @jobs

  @doc """
  The jobs that belong to one source.

  **A job of a source belongs on the page of that source**, and not on a page of its
  own. Reading the trending list means nothing without podcasts, and it must not run for
  a source that a person turned off or that holds no key. `MyHiFiWeb.SettingsLive` draws
  the period of each of these inside the section of the source, so the periods sit beside
  the key that they need.
  """
  @spec jobs_for(module()) :: [map()]
  def jobs_for(source), do: Enum.filter(@jobs, &(&1.source == source))

  @doc """
  The Oban workers that this process drives.

  `MyHiFi.Application` takes each one out of the crontab that `AshOban.config/2` builds,
  so a clock starts none of them and this process is the one way that they arrive. The
  `schedule` block of each resource stays, because `AshOban.schedule/2` reads it.
  """
  @spec workers() :: [module()]
  def workers, do: Enum.map(@jobs, & &1.worker)

  @doc """
  The settings key that holds the period of one job.

      iex> MyHiFi.AutoSync.hours_key("radio")
      "sync.radio.hours"
  """
  @spec hours_key(String.t()) :: String.t()
  def hours_key(key), do: "sync." <> key <> ".hours"

  @doc """
  The settings key that holds the time that one job last ran.

      iex> MyHiFi.AutoSync.last_key("radio")
      "sync.radio.last-run"
  """
  @spec last_key(String.t()) :: String.t()
  def last_key(key), do: "sync." <> key <> ".last-run"

  @doc "The hours between two runs of one job, or 0 for a job that never runs."
  @spec hours(String.t()) :: non_neg_integer()
  def hours(key) do
    case Settings.fetch(hours_key(key)) do
      {:ok, %{value: value}} -> parse_hours(value, key)
      {:error, _reason} -> default_hours(key)
    end
  end

  @doc """
  Set the hours between two runs of one job.

  0 turns that job off, and the longest period is #{@max_hours} hours.
  """
  @spec set_hours(String.t(), non_neg_integer()) :: :ok | {:error, :out_of_range | :no_such_job}
  def set_hours(key, new_hours) when is_integer(new_hours) and new_hours in 0..@max_hours do
    case job(key) do
      nil ->
        {:error, :no_such_job}

      _job ->
        Settings.put!(hours_key(key), to_string(new_hours))

        :ok
    end
  end

  def set_hours(_key, _hours), do: {:error, :out_of_range}

  @doc "The time that one job last ran, or `nil` for a job that never ran."
  @spec last_run(String.t()) :: DateTime.t() | nil
  def last_run(key) do
    with {:ok, %{value: value}} <- Settings.fetch(last_key(key)),
         {:ok, at, _offset} <- DateTime.from_iso8601(value) do
      at
    else
      _other -> nil
    end
  end

  @doc """
  Whether one job needs to run now.

  A job that never ran is due, which is what fills the catalogue of a new device. A job
  whose period is 0 is never due.

  It reads one setting and compares two times, and it asks the network nothing. See the
  moduledoc for why that matters.
  """
  @spec due?(String.t(), DateTime.t()) :: boolean()
  def due?(key, now \\ DateTime.utc_now()) do
    with %{source: source} <- job(key),
         true <- Source.enabled?(source),
         true <- Source.ready?(source) do
      passed?(key, now)
    else
      _other -> false
    end
  end

  defp passed?(key, now) do
    case {hours(key), last_run(key)} do
      {0, _at} -> false
      {_hours, nil} -> true
      {hours, at} -> DateTime.diff(now, at, :hour) >= hours
    end
  end

  @doc """
  Put every job that is due in the queue, and say which ones went.

  `MyHiFi.Device.Monitor` publishes a change of the network, and this runs then. A page
  or a person at the console can call it as well.
  """
  @spec run_due(DateTime.t()) :: [String.t()]
  def run_due(now \\ DateTime.utc_now()) do
    for %{key: key} = job <- @jobs, due?(key, now) do
      # The time goes down before the job goes in the queue. See the moduledoc.
      Settings.put!(last_key(key), DateTime.to_iso8601(now))
      AshOban.schedule(job.resource, job.action)

      Logger.info("#{job.title} is due, and the network answers. Asking for it now.")

      key
    end
  end

  @doc false
  @impl GenServer
  def init(options) do
    # The subscription comes before the first read, or a change between the two is lost.
    # See `MyHiFi.Device.Monitor`, which learnt this the hard way.
    :ok = Event.subscribe(:device)

    {:ok, %{tick: Keyword.get(options, :tick, @tick), timer: nil}, {:continue, :first_read}}
  end

  # The device may hold a connection already, and that is the common way for it to
  # start. It runs after `init/1` gives the process to the supervisor, because a read of
  # the network asks another process.
  @doc false
  @impl GenServer
  def handle_continue(:first_read, state), do: {:noreply, tick(run_if_connected(state))}

  @doc false
  @impl GenServer
  def handle_info(%Events.NetworkChanged{interfaces: interfaces}, state) do
    if internet?(interfaces), do: run_due()

    {:noreply, state}
  end

  def handle_info(:tick, state), do: {:noreply, tick(run_if_connected(state))}

  # A change of the sound cards and a change of the free space both arrive here, and
  # neither one says anything about the network.
  def handle_info(%_{}, state), do: {:noreply, state}

  defp run_if_connected(state) do
    if internet?(), do: run_due()

    state
  end

  defp tick(state) do
    %{state | timer: Process.send_after(self(), :tick, state.tick)}
  end

  # A host holds no VintageNet, so `MyHiFi.Device.network/0` gives an empty list there
  # and this answers false. A host therefore runs no job by itself, and a test calls
  # `run_due/1`.
  defp internet?, do: internet?(Device.network!())

  defp internet?(interfaces) do
    Enum.any?(interfaces, &(&1.connection == :internet))
  end

  defp job(key), do: Enum.find(@jobs, &(&1.key == key))

  defp default_hours(key) do
    case job(key) do
      nil -> 0
      %{default_hours: hours} -> hours
    end
  end

  # A person cannot write this value, so a value that no integer reads is a value that
  # an older firmware wrote. The default is the safe answer for it.
  defp parse_hours(value, key) do
    case Integer.parse(value) do
      {hours, ""} when hours >= 0 -> hours
      _other -> default_hours(key)
    end
  end
end
