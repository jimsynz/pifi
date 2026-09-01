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

  ## What else arrives

  Trapping exits also brings the end of every linked port and process here, and a
  peripheral holds hardware that opens both. None of that stops this process. The
  hardware speaks through the callbacks: a bus that is gone gives `{:error, reason}`
  on the next event, and the log then names the event that failed. An exit message
  says much less than that, and a screen must never stop the music.
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

  # The process traps exits, so the end of every linked port and process arrives here.
  # `gen_server` answers the exit of the parent itself, so what reaches this clause
  # belongs to the peripheral. The first start of the PiTFT on the board ended a port
  # with `:normal`, and a clause that read events alone stopped the screen for it.
  @doc false
  @impl GenServer
  def handle_info({:EXIT, _from, :normal}, server), do: {:noreply, server}

  # An exit that is not normal does not stop this process either. The hardware speaks
  # through the callbacks of the peripheral, and the next draw gives `{:error, reason}`
  # for a bus that is gone. That is what stops it, and the log then names the event.
  # A screen must never stop the music, and an exit that this cannot read is a poor
  # reason to take a process down.
  def handle_info({:EXIT, from, reason}, %{module: module} = server) do
    Logger.warning("#{inspect(module)} lost #{inspect(from)}: #{inspect(reason)}")

    {:noreply, server}
  end

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

  # Every event of this firmware is a struct, so a message of another shape belongs to
  # the hardware that the peripheral holds and not to a topic. A GPIO line that a
  # person presses is one of those. See `MyHiFi.Event` and `c:MyHiFi.Peripheral.handle_info/2`.
  def handle_info(message, %{module: module} = server) do
    if function_exported?(module, :handle_info, 2) do
      hardware_message(message, server)
    else
      Logger.debug("#{inspect(module)} read no event in #{inspect(message)}")

      {:noreply, server}
    end
  end

  defp hardware_message(message, %{module: module} = server) do
    case module.handle_info(message, server.state) do
      {:ok, state} ->
        {:noreply, %{server | state: state}}

      {:error, reason} ->
        Logger.error("#{inspect(module)} failed on #{inspect(message)}: #{inspect(reason)}")

        {:stop, reason, server}
    end
  end

  @doc false
  @impl GenServer
  def terminate(reason, %{module: module} = server), do: module.terminate(reason, server.state)
end
