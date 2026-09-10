defmodule MyHiFi.Peripheral.Supervisor do
  @moduledoc """
  Holds the process of each peripheral that runs.

  It starts with no child. `MyHiFi.Peripheral.start_enabled/0` puts each peripheral
  that a person put in use into it, and the settings page puts one in and takes one
  out while the firmware runs.

  **The children are not a static list, and the hardware is the reason.** A child
  that fails to start stops the whole start of a supervisor. A peripheral opens a
  bus, and a bus with nothing on it gives an error, so a static list would let one
  absent screen keep the music from playing. Each peripheral therefore starts on its
  own, and `MyHiFi.Peripheral.start/1` gives the error of that start to the caller.

  The identifier of each child is the module of the peripheral, so one supervisor
  runs a screen and a knob together, and `MyHiFi.Peripheral.stop/1` names one of
  them.
  """

  use Supervisor

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options), do: Supervisor.start_link(__MODULE__, options, name: __MODULE__)

  @doc false
  @impl Supervisor
  def init(_options), do: Supervisor.init([], strategy: :one_for_one)
end
