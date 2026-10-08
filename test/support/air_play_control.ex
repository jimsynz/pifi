defmodule PiFi.Test.AirPlayControl do
  @moduledoc """
  A control socket that writes down what it was asked for.

  `PiFi.AirPlay.ControlSocket` sends a request to whatever address a sender last came
  from, and in a test nothing has come from anywhere, so the real one counts the request
  and sends nothing. This takes the same cast and keeps the arguments, which is what a
  test of `PiFi.AirPlay.AudioSocket` needs to see.
  """

  use GenServer

  @doc false
  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options)

  @doc "Every `{first, count}` it was asked for, oldest first."
  @spec asked(GenServer.server()) :: [{0..65_535, pos_integer()}]
  def asked(control), do: GenServer.call(control, :asked)

  @doc false
  @impl GenServer
  def init(_options), do: {:ok, []}

  @doc false
  @impl GenServer
  def handle_call(:asked, _from, asked), do: {:reply, Enum.reverse(asked), asked}

  @doc false
  @impl GenServer
  def handle_cast({:request, first, count}, asked), do: {:noreply, [{first, count} | asked]}

  def handle_cast(_message, asked), do: {:noreply, asked}
end
