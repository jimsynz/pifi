defmodule MyHiFi.Peripheral.Server do
  @moduledoc """
  The process that a peripheral runs in.

  It subscribes to the topics of `c:MyHiFi.Peripheral.subscriptions/0`, and it calls
  `c:MyHiFi.Peripheral.handle_event/2` for each event that arrives. A peripheral
  module therefore holds no PubSub code and no process code, and a test of a
  peripheral calls the callbacks and needs no process at all.

  ## How to start one

      {MyHiFi.Peripheral.Server, module: MyHiFi.Peripheral.PiTft, rotation: :landscape}

  Every option except `:module` and `:name` goes to `c:MyHiFi.Peripheral.init/1`.
  The name of the process becomes the module, so a caller reaches one peripheral by
  the name of its module and two peripherals never collide.

  ## Why it traps exits

  A screen turns its backlight off in `c:MyHiFi.Peripheral.terminate/2`, and a
  supervisor shutdown does not call `terminate/2` unless the process traps exits.
  A screen that stayed lit after a shutdown would tell a person that the device is
  still awake.

  An event that gives `{:error, reason}` stops the process. The hardware is what
  fails there, and a restart takes hold of it again. A peripheral that wants to
  continue gives `{:ok, state}`, which is what an event that it cannot use gives.
  """

  use GenServer

  require Logger

  alias MyHiFi.Event

  @doc "Start one peripheral. See the module documentation for the options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {module, opts} = Keyword.pop!(opts, :module)
    {name, opts} = Keyword.pop(opts, :name, module)

    GenServer.start_link(__MODULE__, {module, opts}, name: name)
  end

  @doc false
  @impl GenServer
  def init({module, opts}) do
    Process.flag(:trap_exit, true)

    case module.init(opts) do
      {:ok, state} ->
        Enum.each(module.subscriptions(), &Event.subscribe/1)
        {:ok, %{module: module, state: state}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @doc false
  @impl GenServer
  def handle_info(%_{} = event, %{module: module} = server) do
    case module.handle_event(event, server.state) do
      {:ok, state} ->
        {:noreply, %{server | state: state}}

      {:error, reason} ->
        Logger.error(
          "#{inspect(module)} failed on #{inspect(event.__struct__)}: #{inspect(reason)}"
        )

        {:stop, reason, server}
    end
  end

  @doc false
  @impl GenServer
  def terminate(reason, %{module: module} = server), do: module.terminate(reason, server.state)
end
