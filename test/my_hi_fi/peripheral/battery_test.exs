defmodule MyHiFi.Peripheral.BatteryTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Event
  alias MyHiFi.Event.Device, as: Events
  alias MyHiFi.Peripheral.Battery
  alias MyHiFi.Settings

  doctest MyHiFi.Peripheral.Battery, import: true

  # `Wafer.Driver.Fake` answers zero to every read, so a test reads the plumbing and not
  # a number. The one piece of arithmetic here is `percent/1`, and the doctests hold it.
  @fake [driver: Wafer.Driver.Fake, interval: :timer.hours(1)]

  setup do
    Event.subscribe(:device)

    # `Wafer.Driver.Fake` reads 0 percent, so every event here says that the cell is low.
    # This test starts no `MyHiFi.AutoStandby`, so nothing acts on that and the player is
    # left where it was. See `MyHiFi.Application.listening_children/0`.

    on_exit(fn ->
      case Settings.fetch(Battery.low_key()) do
        {:ok, setting} -> Settings.delete!(setting)
        {:error, _reason} -> :ok
      end
    end)

    :ok
  end

  describe "init/1" do
    test "it takes the gauge and reads it once" do
      assert {:ok, state} = Battery.init(@fake)

      assert state.percent == 0
      assert_receive %Events.BatteryChanged{percent: 0, volts: +0.0}
    end

    test "a board that holds no gauge gives the reason, and starts nothing" do
      assert {:error, reason} = Battery.init(bus: "i2c-nothing", address: 0x36)

      assert is_binary(reason) or is_atom(reason) or is_tuple(reason)
    end
  end

  test "it takes no event of any topic" do
    assert Battery.subscriptions() == []
  end

  test "an event of any topic changes nothing" do
    {:ok, state} = Battery.init(@fake)

    assert {:ok, ^state} = Battery.handle_event(%Events.NetworkChanged{}, state)
  end

  describe "reading again" do
    # A cell moves slowly, and the voltage moves at every read. A reader keyed on the
    # voltage would wake the screen once a minute for a number that no person watches.
    test "the same percentage twice publishes one event" do
      {:ok, state} = Battery.init(@fake)
      assert_receive %Events.BatteryChanged{}

      assert {:ok, _state} = Battery.handle_info(:read, state)

      refute_receive %Events.BatteryChanged{}, 200
    end

    test "a percentage that moved publishes an event" do
      {:ok, state} = Battery.init(@fake)
      assert_receive %Events.BatteryChanged{}

      assert {:ok, state} = Battery.handle_info(:read, %{state | percent: 42})

      assert state.percent == 0
      assert_receive %Events.BatteryChanged{percent: 0}
    end

    test "it asks for the next read, so one timer never stops the chain" do
      {:ok, state} = Battery.init(Keyword.put(@fake, :interval, 10))

      assert {:ok, _state} = Battery.handle_info(:read, state)

      assert_receive :read, 500
    end

    test "a message that is not a read changes nothing" do
      {:ok, state} = Battery.init(@fake)

      assert {:ok, ^state} = Battery.handle_info(:something_else, state)
    end
  end

  test "terminate gives the bus back" do
    {:ok, state} = Battery.init(@fake)

    assert :ok = Battery.terminate(:normal, state)
  end

  test "it names itself for the settings page" do
    assert is_binary(Battery.title())
  end

  describe "the point where a person must charge the cell" do
    test "a device that no person changed holds 20 percent" do
      assert Battery.low_percent() == 20
    end

    test "a value that a person set comes back" do
      assert :ok = Battery.set_low_percent(35)

      assert Battery.low_percent() == 35
    end

    # A device that never says anything about a flat cell cannot protect what it writes,
    # and this device cannot turn its own power off.
    test "there is no zero, and no value outside the range" do
      assert {:error, :out_of_range} = Battery.set_low_percent(0)
      assert {:error, :out_of_range} = Battery.set_low_percent(-1)
      assert {:error, :out_of_range} = Battery.set_low_percent(91)
      assert {:error, :out_of_range} = Battery.set_low_percent("a fifth")

      assert Battery.low_percent() == 20
    end

    test "a stored value that this firmware cannot read gives the default" do
      Settings.put!(Battery.low_key(), "a fifth")

      assert Battery.low_percent() == 20
    end

    # Three parts read `low?`, and each one reading the number itself would give three
    # copies that drift. See `MyHiFi.Event.Device.BatteryChanged`.
    #
    # `Wafer.Driver.Fake` answers zero, so a cell above the point cannot be reached here.
    # The board is what covers that: it read 71 percent and `low?` was false.
    test "the event carries the answer, and the fake cell reads 0 percent" do
      {:ok, _state} = Battery.init(@fake)

      assert_receive %Events.BatteryChanged{percent: 0, low?: true}
    end
  end
end
