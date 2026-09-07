defmodule MyHiFi.AutoStandby do
  @moduledoc """
  Enters standby when the device is quiet and no person touches it.

  A stereo that stays awake all night uses power for nothing, and a person who left
  the room does not come back to turn it off. This device therefore does what a stereo
  with an automatic standby does. `MyHiFi.Playback.set_standby_minutes/1` sets the
  period, and 0 turns the timer off.

  **The device is quiet when it plays nothing.** A track that plays holds the timer
  off, so an episode of two hours reaches its end with no press. The period starts
  when the audio stops: after a pause, after the last track of the queue, and after a
  fault.

  **A low battery is the second reason to enter standby**, and it needs no period at all.
  A device that runs on a battery cannot turn its own power off, so the moment that the
  cell reaches the low point is the moment to stop writing and tell a person to charge
  it. See `MyHiFi.Peripheral.Battery` and `MyHiFi.Peripheral.ActivityLed`.

  A control of a person starts the period again, whether the control is a button of
  the board or a click of the web page. Both reach `MyHiFi.Player`, and the player
  publishes what it did. A press that can do nothing, such as a next with nothing
  after it, publishes nothing, so this process reads the `:input` topic as well. A
  person who presses a button touched the device, and what the press achieved does not
  matter here.

  **A person at a browser reaches the player never on most pages**, and the period ran
  out while they read a list. `MyHiFiWeb.Shell` therefore publishes
  `MyHiFi.Event.Input.PageUsed` for each event of each page, and that event starts the
  period again as a press of a button does.

  ## Why this is a process of its own

  `MyHiFi.Player` holds the standby state already, so the timer looks like it belongs
  there. It does not. The player answers a control in more than a dozen clauses, and a
  reset of a timer in each one is a reset that the next clause forgets.

  This process keeps no copy of what the player does. It reads `MyHiFi.Playback.state`
  each time that it sets the timer, so the two can never disagree. The events tell it
  when to read, and nothing more.
  """

  use GenServer

  require Logger

  alias MyHiFi.Event
  alias MyHiFi.Event.Device, as: DeviceEvents
  alias MyHiFi.Event.Input
  alias MyHiFi.Event.Player, as: Events
  alias MyHiFi.Playback
  alias MyHiFi.Settings

  @key "standby.minutes"

  # The period of the ErP rule of the European Union, which a stereo of a shop holds.
  @default_minutes 20

  # The longest period is a day. A person who wants no standby chooses 0.
  @max_minutes 1440

  @doc """
  Start the timer.

  `:minute_ms` is the length of a minute, and a test gives a small number for it. A
  period of 20 minutes cannot be measured in a test suite in any other way.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @doc "The settings key that holds the period."
  @spec key() :: String.t()
  def key, do: @key

  @doc """
  The minutes of quiet that the device waits for.

  0 means that the device waits for a person and enters standby by itself never.
  """
  @spec minutes(GenServer.server()) :: non_neg_integer()
  def minutes(server \\ __MODULE__), do: GenServer.call(server, :minutes)

  @doc """
  Set the minutes of quiet that the device waits for.

  The value stays after a restart. 0 turns the automatic standby off, and the longest
  period is #{@max_minutes} minutes.
  """
  @spec set_minutes(GenServer.server(), non_neg_integer()) :: :ok | {:error, :out_of_range}
  def set_minutes(server \\ __MODULE__, minutes)

  def set_minutes(server, minutes) when is_integer(minutes) and minutes in 0..@max_minutes do
    GenServer.call(server, {:set_minutes, minutes})
  end

  def set_minutes(_server, _minutes), do: {:error, :out_of_range}

  @doc false
  @impl GenServer
  def init(options) do
    # The subscription comes before the first read, or a change between the two is
    # lost. See `MyHiFi.Device.Monitor`, which learnt this the hard way.
    :ok = Event.subscribe(:player)
    :ok = Event.subscribe(:input)
    :ok = Event.subscribe(:device)

    state = %{
      minutes: stored_minutes(),
      minute_ms: Keyword.get(options, :minute_ms, :timer.minutes(1)),
      timer: nil,
      low?: false
    }

    {:ok, state, {:continue, :first_read}}
  end

  # A device that boots and plays nothing is quiet from that moment, so the period
  # starts here and not at the first event. It runs after `init/1` gives the process to
  # the supervisor, because a read of the state asks the player and the player answers
  # a call.
  @doc false
  @impl GenServer
  def handle_continue(:first_read, state), do: {:noreply, reschedule(state)}

  @doc false
  @impl GenServer
  def handle_call(:minutes, _from, state), do: {:reply, state.minutes, state}

  @impl GenServer
  def handle_call({:set_minutes, minutes}, _from, state) do
    Settings.put(@key, to_string(minutes))

    {:reply, :ok, reschedule(%{state | minutes: minutes})}
  end

  @doc false
  @impl GenServer
  def handle_info(:standby, state) do
    if quiet?() do
      Logger.info("Nothing played for #{state.minutes} minutes, and no person pressed a control.")

      report(Playback.standby(true))
    end

    {:noreply, reschedule(%{state | timer: nil})}
  end

  # These five say that the device started to play, or that it stopped. `Progress`,
  # `Buffering` and `MetadataChanged` arrive while a track plays and move nothing here,
  # so a track of an hour costs this process three reads and not three thousand.
  def handle_info(%Events.Started{}, state), do: {:noreply, reschedule(state)}
  def handle_info(%Events.Paused{}, state), do: {:noreply, reschedule(state)}
  def handle_info(%Events.Stopped{}, state), do: {:noreply, reschedule(state)}
  def handle_info(%Events.Failed{}, state), do: {:noreply, reschedule(state)}
  def handle_info(%Events.Standby{}, state), do: {:noreply, reschedule(state)}

  def handle_info(%Input.ButtonPressed{}, state), do: {:noreply, reschedule(state)}
  def handle_info(%Input.PageUsed{}, state), do: {:noreply, reschedule(state)}

  # **A cell that reaches the low point puts the device in standby**, because this device
  # cannot turn its own power off and a person who reads nothing loses what the card
  # holds. See `MyHiFi.Peripheral.Battery`.
  #
  # It acts on the change to low, and not on each event under it. The gauge publishes
  # again at each percentage, so a device that acted on every one of them would go back
  # to standby a minute after a person woke it, and again a minute after that. A person
  # who wakes a device that says "charge now" asked for it while they charge it.
  def handle_info(%DeviceEvents.BatteryChanged{low?: true}, %{low?: false} = state) do
    Logger.warning("The battery reached the low point. The device enters standby.")

    report(Playback.standby(true))

    {:noreply, %{state | low?: true}}
  end

  def handle_info(%DeviceEvents.BatteryChanged{low?: low?}, state),
    do: {:noreply, %{state | low?: low?}}

  def handle_info(%_{}, state), do: {:noreply, state}

  # The device is quiet when it plays nothing and it is awake already. A read comes
  # here and not from a copy, because a track can start in the moment between the
  # message of the timer and this line.
  defp quiet? do
    state = Playback.state!()

    not state.playing? and not state.standby?
  end

  defp reschedule(state) do
    cancel(state.timer)

    if state.minutes > 0 and quiet?() do
      %{state | timer: Process.send_after(self(), :standby, state.minutes * state.minute_ms)}
    else
      %{state | timer: nil}
    end
  end

  # `Process.cancel_timer/1` can arrive too late, and the message of a timer that
  # already fired then waits in the mailbox. A read of it here keeps a standby that is
  # minutes early from happening.
  defp cancel(nil), do: :ok

  defp cancel(timer) do
    Process.cancel_timer(timer)

    receive do
      :standby -> :ok
    after
      0 -> :ok
    end
  end

  # A person who set no period gets the period of the rule. A row that holds something
  # that is not a number is a row that no part of this firmware writes, and the default
  # is a better answer than a process that will not start.
  defp stored_minutes do
    with {:ok, %{value: value}} <- Settings.fetch(@key),
         {minutes, ""} when minutes in 0..@max_minutes <- Integer.parse(value) do
      minutes
    else
      _other -> @default_minutes
    end
  end

  # The device is asleep either way, so a standby that the player refused is worth one
  # line of the log and nothing more.
  defp report({:ok, _result}), do: :ok
  defp report({:error, reason}), do: Logger.info("The standby did nothing: #{inspect(reason)}")
end
