defmodule MyHiFi.Peripheral.ServerTest do
  # The firmware starts one PubSub, and this registers a peripheral under the name of
  # its module, so two of these cannot run at the same time.
  use ExUnit.Case, async: false

  alias MyHiFi.Event
  alias MyHiFi.Event.Player
  alias MyHiFi.Peripheral.Server

  defmodule Recorder do
    @moduledoc false

    @behaviour MyHiFi.Peripheral

    @impl MyHiFi.Peripheral
    def title, do: "Recorder"

    @impl MyHiFi.Peripheral
    def init(opts) do
      case Keyword.fetch!(opts, :report_to) do
        {:fail, reason} -> {:error, reason}
        pid -> {:ok, %{report_to: pid, seen: []}}
      end
    end

    @impl MyHiFi.Peripheral
    def subscriptions, do: [:player]

    @impl MyHiFi.Peripheral
    def handle_event(%Player.Failed{reason: reason}, state) do
      send(state.report_to, {:peripheral_failed, reason})
      {:error, reason}
    end

    @impl MyHiFi.Peripheral
    def handle_event(event, state) do
      send(state.report_to, {:peripheral_saw, event})
      {:ok, %{state | seen: [event | state.seen]}}
    end

    @impl MyHiFi.Peripheral
    def terminate(reason, state) do
      send(state.report_to, {:peripheral_terminated, reason, length(state.seen)})
      :ok
    end
  end

  test "it gives each event of a subscribed topic to the peripheral" do
    start_peripheral()

    Event.publish(:player, %Player.Progress{position_ms: 1000, duration_ms: 60_000})

    assert_receive {:peripheral_saw, %Player.Progress{position_ms: 1000}}
  end

  test "it gives no event of a topic that the peripheral does not take" do
    start_peripheral()

    Event.publish(:view, %Player.Progress{position_ms: 1000})
    Event.publish(:player, %Player.Paused{position_ms: 2000})

    assert_receive {:peripheral_saw, %Player.Paused{}}
    refute_received {:peripheral_saw, %Player.Progress{}}
  end

  test "it registers under the name of the peripheral module" do
    start_peripheral()

    assert is_pid(Process.whereis(Recorder))
  end

  test "it stops when the peripheral cannot take hold of the hardware" do
    Process.flag(:trap_exit, true)

    assert {:error, :no_such_device} =
             Server.start_link(module: Recorder, report_to: {:fail, :no_such_device})
  end

  test "it calls terminate when it shuts down, so a screen turns its backlight off" do
    pid = start_peripheral()

    Event.publish(:player, %Player.Paused{position_ms: 1})
    assert_receive {:peripheral_saw, %Player.Paused{}}

    GenServer.stop(pid, :normal)

    assert_receive {:peripheral_terminated, :normal, 1}
  end

  test "it stops when an event fails, because the hardware is what failed" do
    Process.flag(:trap_exit, true)
    {:ok, pid} = Server.start_link(module: Recorder, report_to: self())

    Event.publish(:player, %Player.Failed{reason: :bus_gone})

    assert_receive {:peripheral_failed, :bus_gone}
    assert_receive {:EXIT, ^pid, :bus_gone}
  end

  describe "a message that is not an event" do
    test "a port that ends keeps the peripheral running" do
      pid = start_peripheral()

      send(pid, {:EXIT, self(), :normal})

      assert Process.alive?(pid)
      assert_saw_an_event(pid)
    end

    test "a link that ends badly keeps the peripheral running" do
      pid = start_peripheral()

      send(pid, {:EXIT, self(), :bus_gone})

      assert Process.alive?(pid)
      assert_saw_an_event(pid)
    end

    test "anything else keeps the peripheral running" do
      pid = start_peripheral()

      send(pid, {:tcp_closed, make_ref()})
      send(pid, :hello)

      assert Process.alive?(pid)
      assert_saw_an_event(pid)
    end
  end

  # A peripheral that still answers an event is one that the message did not break.
  defp assert_saw_an_event(pid) do
    Event.publish(:player, %Player.Paused{position_ms: 7})

    assert_receive {:peripheral_saw, %Player.Paused{position_ms: 7}}
    assert Process.alive?(pid)
  end

  # `start_supervised!` and not `start_link`, because a peripheral registers under the
  # name of its module. A linked process dies when the test does, and it deregisters
  # after that, so the next test would race with it for the name.
  defp start_peripheral, do: start_supervised!({Server, module: Recorder, report_to: self()})
end
