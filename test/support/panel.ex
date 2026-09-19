defmodule PiFi.Test.Panel do
  @moduledoc """
  A peripheral that says it draws a screen, and holds no hardware.

  `PiFi.Test.Lamp` is the peripheral that a test names when it needs one of no
  particular kind. This one is for a test of the parts that a screen brings, such as
  the page that sets how long a screen waits before it goes dark.

      Application.put_env(:pifi, :peripherals, [{PiFi.Test.Panel, []}])
  """

  @behaviour PiFi.Peripheral

  @impl PiFi.Peripheral
  def title, do: "Panel"

  @impl PiFi.Peripheral
  def screen?, do: true

  @impl PiFi.Peripheral
  def init(_options), do: {:ok, %{}}

  @impl PiFi.Peripheral
  def subscriptions, do: [:view]

  @impl PiFi.Peripheral
  def handle_event(_event, state), do: {:ok, state}

  @impl PiFi.Peripheral
  def terminate(_reason, _state), do: :ok
end
