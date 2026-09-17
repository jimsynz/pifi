defmodule PiFi.Test.Lamp do
  @moduledoc """
  A peripheral of no hardware.

  A test that needs a peripheral names this one, in the way that a test that needs a
  source names `PiFi.Test.PlainSource`.

      Application.put_env(:pifi, :peripherals, [{PiFi.Test.Lamp, []}])

  Two options change what it does. `:fault` makes `c:PiFi.Peripheral.init/1` answer
  in the way that a screen with nothing wired to it does. `:report_to` names a process
  that gets a message when `c:PiFi.Peripheral.terminate/2` runs, so a test can prove
  that a stop turns the hardware off.
  """

  @behaviour PiFi.Peripheral

  @impl PiFi.Peripheral
  def title, do: "Lamp"

  @impl PiFi.Peripheral
  def init(options) do
    case Keyword.fetch(options, :fault) do
      {:ok, reason} -> {:error, reason}
      :error -> {:ok, %{report_to: Keyword.get(options, :report_to)}}
    end
  end

  @impl PiFi.Peripheral
  def subscriptions, do: [:player]

  @impl PiFi.Peripheral
  def handle_event(_event, state), do: {:ok, state}

  @impl PiFi.Peripheral
  def terminate(_reason, %{report_to: nil}), do: :ok

  def terminate(reason, state) do
    send(state.report_to, {:lamp_terminated, reason})
    :ok
  end
end
