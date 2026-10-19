defmodule PiFi.Test.FakeKnobBoard do
  @moduledoc """
  A stand-in for `FocPeripheral`, so a test of `PiFi.Peripheral.HapticKnobs` needs no
  board and no serial port.

  It answers the two calls that the peripheral makes, and it sends each setting to the
  test as `{:knob_set, index, settings}`. A test plays the board's side by sending the
  peripheral `{FocPeripheral, event}` itself.
  """

  use GenServer

  @doc "Start a board that reports to the calling process."
  @spec start_link(pid()) :: GenServer.on_start()
  def start_link(test), do: GenServer.start_link(__MODULE__, test)

  @impl GenServer
  def init(test), do: {:ok, test}

  @impl GenServer
  def handle_call(:subscribe, _from, test), do: {:reply, %{}, test}

  def handle_call({:set, index, settings}, _from, test) do
    send(test, {:knob_set, index, settings})
    {:reply, :ok, test}
  end
end
