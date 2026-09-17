defmodule PiFi.Peripheral.ServerTest do
  # The firmware starts one PubSub, and this registers a peripheral under the name of
  # its module, so two of these cannot run at the same time.
  use ExUnit.Case, async: false

  alias PiFi.Event
  alias PiFi.Event.Player
  alias PiFi.Peripheral.Server

  defmodule Recorder do
    @moduledoc false

    @behaviour PiFi.Peripheral

    @impl PiFi.Peripheral
    def title, do: "Recorder"

    @impl PiFi.Peripheral
    def init(opts) do
      case Keyword.fetch!(opts, :report_to) do
        {:fail, reason} -> {:error, reason}
        pid -> {:ok, %{report_to: pid, seen: []}}
      end
    end

    @impl PiFi.Peripheral
    def subscriptions, do: [:player]

    @impl PiFi.Peripheral
    def handle_event(%Player.Failed{reason: reason}, state) do
      send(state.report_to, {:peripheral_failed, reason})
      {:error, reason}
    end

    @impl PiFi.Peripheral
    def handle_event(event, state) do
      send(state.report_to, {:peripheral_saw, event})
      {:ok, %{state | seen: [event | state.seen]}}
    end

    @impl PiFi.Peripheral
    def terminate(reason, state) do
      send(state.report_to, {:peripheral_terminated, reason, length(state.seen)})
      :ok
    end
  end

  # Hardware speaks to the process that holds it, and a peripheral that names
  # `handle_info/2` reads what it sends. See `PiFi.Peripheral.PiTft`.
  defmodule Listener do
    @moduledoc false

    @behaviour PiFi.Peripheral

    @impl PiFi.Peripheral
    def title, do: "Listener"

    @impl PiFi.Peripheral
    def init(opts), do: {:ok, %{report_to: Keyword.fetch!(opts, :report_to)}}

    @impl PiFi.Peripheral
    def subscriptions, do: []

    @impl PiFi.Peripheral
    def handle_event(_event, state), do: {:ok, state}

    @impl PiFi.Peripheral
    def handle_info(:break, _state), do: {:error, :the_line_is_gone}

    def handle_info(message, state) do
      send(state.report_to, {:peripheral_heard, message})
      {:ok, state}
    end

    @impl PiFi.Peripheral
    def terminate(_reason, _state), do: :ok
  end

  describe "a message that the hardware sends" do
    test "it reaches a peripheral that names handle_info/2" do
      {:ok, pid} = Server.start_link(module: Listener, report_to: self())

      send(pid, {:circuits_gpio, 27, 1_000, 0})

      assert_receive {:peripheral_heard, {:circuits_gpio, 27, 1_000, 0}}
      assert Process.alive?(pid)
    end

    test "a failure stops the peripheral, because the hardware is what failed" do
      Process.flag(:trap_exit, true)
      {:ok, pid} = Server.start_link(module: Listener, report_to: self())

      send(pid, :break)

      assert_receive {:EXIT, ^pid, :the_line_is_gone}
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
