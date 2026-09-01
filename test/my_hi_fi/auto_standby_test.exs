defmodule MyHiFi.AutoStandbyTest do
  # It reads the player, which one process holds for the whole firmware.
  use MyHiFi.DataCase, async: false

  alias MyHiFi.AutoStandby
  alias MyHiFi.Event
  alias MyHiFi.Event.Input
  alias MyHiFi.Event.Player
  alias MyHiFi.Playback
  alias MyHiFi.Settings

  # A period of 20 minutes cannot be measured in a test suite, so each instance here
  # holds a minute of 10 ms. See `MyHiFi.AutoStandby.start_link/1`.
  @minute_ms 10

  setup do
    :ok = Event.subscribe(:player)

    on_exit(fn ->
      Playback.standby(false)
      Playback.set_standby_minutes(20)
    end)

    :ok
  end

  defp start_timer(options \\ []) do
    [name: :auto_standby_test, minute_ms: @minute_ms]
    |> Keyword.merge(options)
    |> AutoStandby.start_link()
    |> then(fn {:ok, pid} -> pid end)
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

    test "the action reads and writes the period" do
      assert {:ok, :ok} = Playback.set_standby_minutes(30)
      assert Playback.standby_minutes!() == 30
    end
  end
end
