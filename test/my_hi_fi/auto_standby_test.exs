defmodule MyHiFi.AutoStandbyTest do
  # It reads the player, which one process holds for the whole firmware.
  use MyHiFi.DataCase, async: false

  alias MyHiFi.AutoStandby
  alias MyHiFi.Event
  alias MyHiFi.Event.Device, as: DeviceEvents
  alias MyHiFi.Event.Input
  alias MyHiFi.Event.Player
  alias MyHiFi.Playback
  alias MyHiFi.Settings

  # A period of 20 minutes cannot be measured in a test suite, so each instance here
  # holds a minute of 10 ms. See `MyHiFi.AutoStandby.start_link/1`.
  @minute_ms 10

  setup do
    :ok = Event.subscribe(:player)

    # The player is one process for the whole node, so its standby state must go back.
    # The period is a row, and it outlives a test, so the row goes: the process that
    # held a copy of it belongs to this test alone now and is gone by here.
    on_exit(fn ->
      Playback.standby(false)

      case Settings.fetch(AutoStandby.key()) do
        {:ok, setting} -> Settings.delete!(setting)
        {:error, _reason} -> :ok
      end
    end)

    :ok
  end

  # The application starts one of these, and each test starts another. Both are
  # subscribed, so one low cell gives two standby events. A test that refutes a later one
  # must therefore take the ones that it already asked for out of the mailbox.
  defp drain_standby do
    receive do
      %Player.Standby{} -> drain_standby()
    after
      100 -> :ok
    end
  end

  # `MyHiFi.Application` starts none of these in the test environment, so a test gets the
  # one that it asks for and no other. See `MyHiFi.Application.listening_children/0`.
  defp start_timer(options \\ []) do
    options = Keyword.merge([name: :auto_standby_test, minute_ms: @minute_ms], options)

    # `start_supervised!/1` reads the identifier of a child from the module, so two of
    # these in one test collide. The name is what tells them apart.
    {AutoStandby, options}
    |> Supervisor.child_spec(id: Keyword.fetch!(options, :name))
    |> start_supervised!()
  end

  describe "the period of quiet" do
    test "the device enters standby when it plays nothing for the period" do
      start_timer()

      assert_receive %Player.Standby{entered?: true}, 5000
    end

    test "a period of 0 keeps the device awake" do
      Settings.put("standby.minutes", "0")
      start_timer()

      refute_receive %Player.Standby{}, 500
    end

    test "a device that is in standby already gets no second standby" do
      {:ok, :ok} = Playback.standby(true)
      assert_receive %Player.Standby{entered?: true}, 5000

      start_timer()

      refute_receive %Player.Standby{}, 500
    end

    test "a press of a button starts the period again" do
      pid = start_timer()

      # Each press arrives inside one period, so the timer never runs out while they
      # continue. The device is quiet the whole time, and it stays awake.
      Enum.each(1..20, fn _ ->
        Event.publish(:input, %Input.ButtonPressed{peripheral: MyHiFi.Peripheral.PiTft, button: 2})

        Process.sleep(10)
      end)

      refute_receive %Player.Standby{}, 100

      # The presses stop, and the device then enters standby by itself.
      assert Process.alive?(pid)
      assert_receive %Player.Standby{entered?: true}, 5000
    end

    test "a person who uses a web page starts the period again" do
      pid = start_timer()

      # A person who browses a list reaches the player never, so the page is what says
      # that they are there. See `MyHiFiWeb.Shell`.
      Enum.each(1..20, fn _ ->
        Event.publish(:input, %Input.PageUsed{page: MyHiFiWeb.BrowseLive})

        Process.sleep(10)
      end)

      refute_receive %Player.Standby{}, 100

      assert Process.alive?(pid)
      assert_receive %Player.Standby{entered?: true}, 5000
    end
  end

  # This device cannot turn its own power off, so a cell that reaches the low point is
  # the moment to stop writing and tell a person to charge it. See
  # `MyHiFi.Peripheral.Battery`.
  describe "a cell that is nearly flat" do
    test "the device enters standby at once, and waits for no period" do
      start_timer(minute_ms: :timer.minutes(1))

      Event.publish(:device, %DeviceEvents.BatteryChanged{percent: 20, volts: 3.6, low?: true})

      assert_receive %Player.Standby{entered?: true}, 2000
    end

    # The gauge publishes again at each percentage under the point. A device that acted
    # on every one of them would go back to standby a minute after a person woke it, and
    # again a minute after that.
    test "a second event under the point does not put it back" do
      start_timer(minute_ms: :timer.minutes(1))

      Event.publish(:device, %DeviceEvents.BatteryChanged{percent: 20, volts: 3.6, low?: true})
      assert_receive %Player.Standby{entered?: true}, 2000
      drain_standby()

      {:ok, :ok} = Playback.standby(false)
      drain_standby()

      Event.publish(:device, %DeviceEvents.BatteryChanged{percent: 19, volts: 3.5, low?: true})

      refute_receive %Player.Standby{entered?: true}, 500
    end

    test "a cell that is charged again arms the warning for the next time" do
      start_timer(minute_ms: :timer.minutes(1))

      Event.publish(:device, %DeviceEvents.BatteryChanged{percent: 20, volts: 3.6, low?: true})
      assert_receive %Player.Standby{entered?: true}, 2000
      drain_standby()

      Event.publish(:device, %DeviceEvents.BatteryChanged{percent: 80, volts: 4.0, low?: false})
      {:ok, :ok} = Playback.standby(false)
      drain_standby()

      Event.publish(:device, %DeviceEvents.BatteryChanged{percent: 20, volts: 3.6, low?: true})

      assert_receive %Player.Standby{entered?: true}, 2000
    end

    test "a cell above the point puts nothing in standby" do
      start_timer(minute_ms: :timer.minutes(1))

      drain_standby()

      Event.publish(:device, %DeviceEvents.BatteryChanged{percent: 80, volts: 4.0, low?: false})

      refute_receive %Player.Standby{entered?: true}, 500
    end
  end

  describe "the setting" do
    test "a device that holds no value waits for 20 minutes" do
      pid = start_timer()

      assert AutoStandby.minutes(pid) == 20
    end

    test "a value that is not a number gives the default" do
      Settings.put("standby.minutes", "soon")
      pid = start_timer()

      assert AutoStandby.minutes(pid) == 20
    end

    test "a value stays after a restart" do
      pid = start_timer()
      :ok = AutoStandby.set_minutes(pid, 45)

      assert {:ok, %{value: "45"}} = Settings.fetch("standby.minutes")
      assert AutoStandby.minutes(start_timer(name: :auto_standby_restarted)) == 45
    end

    test "a period longer than a day is refused" do
      pid = start_timer()

      assert {:error, :out_of_range} = AutoStandby.set_minutes(pid, 1441)
      assert {:error, :out_of_range} = AutoStandby.set_minutes(pid, -1)
    end

    # `MyHiFi.Playback.Player` names the process for the whole node, so the action needs
    # one under that name. Every other test here holds its own and needs no such thing.
    test "the action reads and writes the period" do
      start_timer(name: AutoStandby)

      assert {:ok, :ok} = Playback.set_standby_minutes(30)
      assert Playback.standby_minutes!() == 30
    end
  end
end
