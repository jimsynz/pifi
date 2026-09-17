defmodule PiFi.Peripheral.Battery do
  @moduledoc """
  The fuel gauge of the UPS-Lite pHAT, over I2C.

  The board has a MAX17040, which reports the voltage of the cell and the charge of it
  as a percentage. `max1704x` is the driver, and `wafer` is the layer between it and
  `circuits_i2c`. This module reads the two numbers on a timer and publishes
  `PiFi.Event.Device.BatteryChanged` when the percentage moves.

  ## Why a peripheral, and not a process of its own

  `PiFi.Peripheral` says "a piece of hardware that a person sees or touches", and a
  fuel gauge is neither. **That sentence describes the parts that came first, and not
  the rule.** The rule is the one that `PiFi.Peripheral.enabled?/1` names: the same
  image runs on a board that has this part and on a board that does not, and a bus
  with nothing on it gives an error at each start. That is exactly true of a gauge. One
  of these two devices runs on a battery and the other one sits on a stereo.

  A process of its own would need its own setting, its own start and stop, and its own
  row on the settings page, and each one would be a copy of what this behaviour already
  holds.

  ## The point where a person must charge it

  `low_percent/0` names that number, and the event carries the answer as `low?`. **Three
  parts act on it**: `PiFi.AutoStandby` puts the device in standby,
  `PiFi.Peripheral.ActivityLed` flashes the light that shows through the case, and the
  screen of `PiFi.Peripheral.PirateAudio` says to charge it. The number is here so that
  the three cannot drift apart, and a person sets it.

  ## It reads on a timer, and it publishes rarely

  A cell moves slowly, so a read each minute is ample and it costs one short exchange on
  the bus. **The event goes out when the percentage moves**, and not at each read. The
  voltage moves at every read, so a reader keyed on that would wake the screen once a
  minute for a number that no person is watching.

  ## It does not quickstart the gauge, and that is deliberate

  `Max1704x.quickstart!/1` tells the chip to throw its model away and guess again from
  the voltage that it reads at that moment. An earlier version of this module did that at
  every `init/1`, on the reasoning that a device which lost its power has a gauge that
  kept counting. **That reasoning is backwards, and a measurement on the board on
  2026-09-01 showed it.**

  The gauge takes its power from the cell and not from the Raspberry Pi, so it keeps
  counting through every boot, every upgrade and every hour that the device spends
  switched off. Its model is therefore the best answer that this device has, and a
  quickstart replaces it with a worse one.

  It also gives a wrong number at the worst moment. A read straight after a quickstart
  gave 33 percent as 21, and six reads a minute later were steady at 33.41. A device that
  trusted the first of those would enter standby and flash the light for a cell that held
  a third of its charge.

  A cell that a person swaps is the one case that wants a quickstart, and that is a
  control for a person to press and not a thing to do at each start.
  """

  @behaviour PiFi.Peripheral

  alias PiFi.Event
  alias PiFi.Event.Device, as: Events
  alias PiFi.Settings
  alias Wafer.Driver.Circuits.I2C, as: Driver

  require Logger

  # The MAX17040 answers at this address, and the UPS-Lite puts it on the one bus that
  # the header carries.
  @address 0x36
  @bus "i2c-1"

  # A cell moves slowly. This is the period between two reads, and not the period
  # between two events.
  @interval :timer.minutes(1)

  # Every reader reads this and one process writes it, at most once a minute and only
  # when the percentage moves. `:persistent_term` is made for that shape. A write of one
  # scans the processes of the node, so a value that moved at each read would be the
  # wrong thing to keep here.
  @term {__MODULE__, :last_reading}

  @low_key "battery.low-percent"
  @default_low 20
  @max_low 90

  @doc "The name that the settings page draws."
  @impl PiFi.Peripheral
  def title, do: "UPS-Lite battery gauge"

  @doc """
  The last reading of the gauge, or `nil` for a device with none.

  **An event says that a number changed, and it says nothing to a reader that arrives
  after it.** A page that a person opens, and a screen that starts, both need the number
  that the device reads now, and this gauge reports a change once a minute at most. A
  reader that waited for an event would therefore draw nothing for a minute, or for an
  hour if the cell is steady.

  A device with no gauge returns `nil`, and so does one whose gauge a person turned
  off. **A reader draws nothing for `nil`, and never a battery at 0.**

  **The reading carries the process that took it, and this asks whether that process
  still lives.** `terminate/2` erases the value, and a process that crashes runs no
  `terminate/2`, so a gauge that a person unplugged would otherwise leave a number that
  never moves again on every screen.

  **It asks the process and never the supervisor.** `PiFi.Peripheral.running?/1` reads
  `Supervisor.which_children/1`, and a screen calls this from its own `init/1`, which
  runs inside `Supervisor.start_child/2` while that supervisor waits for it. The
  supervisor therefore cannot answer, the screen never starts, and the whole application
  hangs. A device on 2026-09-02 did that and needed the watchdog to bring it back.
  `Process.alive?/1` asks nothing of any supervisor.
  """
  @spec last_reading() :: Events.BatteryChanged.t() | nil
  def last_reading do
    case :persistent_term.get(@term, nil) do
      {pid, reading} -> if Process.alive?(pid), do: reading
      _none -> nil
    end
  end

  @doc "The settings key of the point where the cell counts as low."
  @spec low_key() :: String.t()
  def low_key, do: @low_key

  @doc """
  The percentage at which a person must charge the cell.

  `PiFi.AutoStandby` puts the device in standby there, `PiFi.Peripheral.ActivityLed`
  flashes there, and the screen says to charge it there. The number lives here so that
  the three cannot disagree.
  """
  @spec low_percent() :: pos_integer()
  def low_percent do
    case Settings.fetch(@low_key) do
      {:ok, %{value: value}} -> parse_low(value)
      {:error, _reason} -> @default_low
    end
  end

  @doc """
  Set the percentage at which a person must charge the cell.

  The lowest is 1 and the highest is #{@max_low}. There is no 0: a device that never
  says anything about a flat cell cannot protect what it writes, and this device cannot
  turn its own power off.
  """
  @spec set_low_percent(pos_integer()) :: :ok | {:error, :out_of_range}
  def set_low_percent(percent) when is_integer(percent) and percent in 1..@max_low do
    Settings.put!(@low_key, to_string(percent))

    :ok
  end

  def set_low_percent(_percent), do: {:error, :out_of_range}

  @doc """
  Take hold of the gauge and read it once.

  ## Options

  - `:bus` - the I2C bus of the gauge. `"i2c-1"` by default.
  - `:address` - the address of the chip. `0x36` by default.
  - `:interval` - the time between two reads. One minute by default.
  - `:driver` - the Wafer driver of the bus. `Wafer.Driver.Circuits.I2C` by default. A
    test gives `Wafer.Driver.Fake`, which answers zero to every read.

  **A board with no gauge gives an error here, and it needs no code of ours.**
  `Wafer.Driver.Circuits.I2C.acquire/1` reads the devices of the bus and refuses an
  address that nothing answers at, so the settings page shows "No device detected at
  address" to the person who asked. That is the whole reason a peripheral stays out of
  use until a person says that the part is wired.
  """
  @impl PiFi.Peripheral
  def init(opts) do
    driver = Keyword.get(opts, :driver, Driver)
    bus = Keyword.get(opts, :bus, @bus)
    address = Keyword.get(opts, :address, @address)

    with {:ok, conn} <- driver.acquire(bus_name: bus, address: address),
         {:ok, gauge} <- Max1704x.acquire(conn: conn, variant: :max17040) do
      state = %{gauge: gauge, percent: nil, interval: Keyword.get(opts, :interval, @interval)}

      {:ok, read(state)}
    end
  end

  @doc "The gauge reads hardware and takes no event of any topic."
  @impl PiFi.Peripheral
  def subscriptions, do: []

  @doc false
  @impl PiFi.Peripheral
  def handle_event(_event, state), do: {:ok, state}

  @doc "Read the gauge again, on the timer that `init/1` started."
  @impl PiFi.Peripheral
  def handle_info(:read, state), do: {:ok, read(state)}

  def handle_info(_message, state), do: {:ok, state}

  @doc """
  Give the bus back, and forget the last reading.

  A person who turns the gauge off has a device that reports no charge, so every
  reader must stop drawing one. See `last_reading/0`.
  """
  @impl PiFi.Peripheral
  def terminate(_reason, state) do
    :persistent_term.erase(@term)
    Wafer.Release.release(state.gauge.conn)

    :ok
  end

  defp read(state) do
    Process.send_after(self(), :read, state.interval)

    case measure(state.gauge) do
      {:ok, percent, volts} -> publish(state, percent, volts)
      {:error, reason} -> report(state, reason)
    end
  end

  # A gauge that does not answer must never stop this process. A cell that is charging
  # takes the bus for a moment on some boards, and a device that plays music through a
  # screen that works is worth more than an exact percentage.
  defp report(state, reason) do
    Logger.warning("The battery gauge did not answer: #{inspect(reason)}")

    state
  end

  defp measure(gauge) do
    with {:ok, charge} <- Max1704x.current_charge(gauge),
         {:ok, volts} <- Max1704x.current_voltage(gauge) do
      {:ok, percent(charge), volts}
    end
  end

  # A person can write no value here, so a value that no integer reads is one that an
  # older firmware wrote. The default is the safe answer for it.
  defp parse_low(value) do
    case Integer.parse(value) do
      {percent, ""} when percent in 1..@max_low -> percent
      _other -> @default_low
    end
  end

  # The event goes out when the percentage moves, and not at each read. See the
  # moduledoc.
  defp publish(%{percent: percent} = state, percent, _volts), do: state

  defp publish(state, percent, volts) do
    event = %Events.BatteryChanged{
      percent: percent,
      volts: volts,
      low?: percent <= low_percent()
    }

    :persistent_term.put(@term, {self(), event})
    Event.publish(:device, event)

    %{state | percent: percent}
  end

  @doc """
  The percentage that a person reads, from the charge that the gauge reports.

  **The gauge reports more than 100 for a cell that is full and charging**, and it can
  report less than nothing for one that is flat. A person reads no such number on any
  other device, so this keeps it inside the range that they expect.

      iex> PiFi.Peripheral.Battery.percent(71.4)
      71

      iex> PiFi.Peripheral.Battery.percent(104.2)
      100

      iex> PiFi.Peripheral.Battery.percent(-0.5)
      0
  """
  @spec percent(float()) :: 0..100
  def percent(charge) do
    charge
    |> round()
    |> max(0)
    |> min(100)
  end
end
