defmodule MyHiFi.Peripheral.ActivityLedTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Event.Device, as: Events
  alias MyHiFi.Peripheral.ActivityLed

  # The light is files in `/sys`, so a directory of files is the whole of it. A test
  # therefore reads what the driver wrote and needs no board.
  setup do
    path = Path.join(System.tmp_dir!(), "activity-led-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    for file <- ~w[trigger brightness delay_on delay_off],
        do: File.write!(Path.join(path, file), "")

    on_exit(fn -> File.rm_rf(path) end)

    {:ok, state} = ActivityLed.init(path: path)

    %{path: path, state: state}
  end

  defp read(path, file), do: File.read!(Path.join(path, file))

  describe "init/1" do
    test "it leaves the light dark and takes no trigger", %{path: path} do
      assert read(path, "trigger") == "none"
      assert read(path, "brightness") == "0"
    end

    test "a board whose light is not there gives the reason" do
      assert {:error, _reason} = ActivityLed.init(path: "/sys/class/leds/nothing-here")
    end
  end

  test "it reads the device topic alone" do
    assert ActivityLed.subscriptions() == [:device]
  end

  describe "a cell that is low" do
    # The kernel flashes the light, and this process does not. A process that wrote the
    # brightness itself would wake four times a second and stop the moment that it died.
    test "it gives the light to the timer of the kernel", %{path: path, state: state} do
      assert {:ok, state} = ActivityLed.handle_event(%Events.BatteryChanged{low?: true}, state)

      assert state.flashing?
      assert read(path, "trigger") == "timer"
      assert read(path, "delay_on") == "100"
      assert read(path, "delay_off") == "100"
    end

    test "a second event writes nothing more", %{path: path, state: state} do
      {:ok, state} = ActivityLed.handle_event(%Events.BatteryChanged{low?: true}, state)
      File.write!(Path.join(path, "trigger"), "untouched")

      assert {:ok, _state} = ActivityLed.handle_event(%Events.BatteryChanged{low?: true}, state)

      assert read(path, "trigger") == "untouched"
    end
  end

  describe "a cell that is no longer low" do
    test "it takes the light back and leaves it dark", %{path: path, state: state} do
      {:ok, state} = ActivityLed.handle_event(%Events.BatteryChanged{low?: true}, state)

      assert {:ok, state} = ActivityLed.handle_event(%Events.BatteryChanged{low?: false}, state)

      refute state.flashing?
      assert read(path, "trigger") == "none"
      assert read(path, "brightness") == "0"
    end

    test "a light that never flashed writes nothing", %{path: path, state: state} do
      File.write!(Path.join(path, "trigger"), "untouched")

      assert {:ok, _state} = ActivityLed.handle_event(%Events.BatteryChanged{low?: false}, state)

      assert read(path, "trigger") == "untouched"
    end
  end

  test "an event that says nothing about the cell changes nothing", %{state: state} do
    assert {:ok, ^state} = ActivityLed.handle_event(%Events.NetworkChanged{}, state)
  end

  test "terminate leaves the light dark", %{path: path, state: state} do
    {:ok, state} = ActivityLed.handle_event(%Events.BatteryChanged{low?: true}, state)

    assert :ok = ActivityLed.terminate(:normal, state)

    assert read(path, "trigger") == "none"
    assert read(path, "brightness") == "0"
  end

  test "it names itself for the settings page" do
    assert is_binary(ActivityLed.title())
  end
end
