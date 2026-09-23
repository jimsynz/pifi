defmodule PiFi.Bluetooth.Agent do
  @moduledoc """
  The thing BlueZ asks before it will finish a pairing.

  **Pairing does not complete without one of these, and it fails quietly.** BlueZ
  answered `Pair` with `:ok`, the headset connected for a few seconds, and no link key
  was ever written — so there was no bond, the link had no authentication, AVDTP
  refused the audio transport with `Permission denied`, and the connection dropped. Four
  symptoms, one cause, and none of them says "no agent".

  ## This device has no keypad and no screen

  So the capability is `NoInputNoOutput`, which is the case the specification calls Just
  Works: no code is shown and none is typed, and the two sides bond on the strength of
  being in pairing mode at the same moment. **That is the same assurance AirPlay 1 has**,
  and it is the right one for a stereo — a person holding a button on a headset is the
  authorisation.

  Every request is therefore approved. That reads alarmingly and it is what
  `NoInputNoOutput` means: a device that cannot ask a person anything cannot refuse on
  their behalf either. What keeps this safe is that `PiFi.Bluetooth.Devices.discover/0`
  runs when a person asks for it and not otherwise.

  ## Serving a D-Bus object rather than calling one

  Everything else here calls BlueZ. This is called *by* it, which is the other direction
  and a different part of the library: an object is registered against the service that
  `dbus_service_reg` keeps, and a call addressed to this connection falls through to it.
  BlueZ introspects the path before it uses it, so `Introspect` is answered too — a path
  that could not describe itself would be registered and never called.
  """

  use GenServer

  require Logger

  alias PiFi.Bluetooth.Bus

  @path "/org/pifi/bluetooth/agent"
  @capability "NoInputNoOutput"
  @manager_path "/org/bluez"
  @manager_interface "org.bluez.AgentManager1"

  @member 3

  # The bus connects in a continue of its own, so the first attempt is often too early.
  @attempts 10
  @retry 1_000

  # What BlueZ may ask a `NoInputNoOutput` agent. Each one is approved by answering with
  # nothing, which is what the specification calls success.
  @approved ~w[Release Cancel RequestAuthorization AuthorizeService RequestConfirmation]

  # Asking for a code or showing one needs a keypad or a screen, and this device has
  # neither. Refusing is the honest answer and BlueZ falls back to Just Works.
  @refused ~w[RequestPinCode DisplayPinCode RequestPasskey DisplayPasskey]

  @introspection """
  <!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
   "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
  <node>
    <interface name="org.bluez.Agent1">
      <method name="Release"/>
      <method name="RequestPinCode"><arg type="o" direction="in"/><arg type="s" direction="out"/></method>
      <method name="DisplayPinCode"><arg type="o" direction="in"/><arg type="s" direction="in"/></method>
      <method name="RequestPasskey"><arg type="o" direction="in"/><arg type="u" direction="out"/></method>
      <method name="DisplayPasskey"><arg type="o" direction="in"/><arg type="u" direction="in"/><arg type="q" direction="in"/></method>
      <method name="RequestConfirmation"><arg type="o" direction="in"/><arg type="u" direction="in"/></method>
      <method name="RequestAuthorization"><arg type="o" direction="in"/></method>
      <method name="AuthorizeService"><arg type="o" direction="in"/><arg type="s" direction="in"/></method>
      <method name="Cancel"/>
    </interface>
    <interface name="org.freedesktop.DBus.Introspectable">
      <method name="Introspect"><arg type="s" direction="out"/></method>
    </interface>
  </node>
  """

  @doc """
  The object path BlueZ is told to call.

      iex> PiFi.Bluetooth.Agent.path()
      "/org/pifi/bluetooth/agent"
  """
  @spec path() :: String.t()
  def path, do: @path

  @doc """
  What this device can ask a person, which is nothing.

      iex> PiFi.Bluetooth.Agent.capability()
      "NoInputNoOutput"
  """
  @spec capability() :: String.t()
  def capability, do: @capability

  @doc "Whether BlueZ has been told about this agent."
  @spec registered?() :: boolean()
  def registered? do
    case GenServer.whereis(__MODULE__) do
      nil -> false
      pid -> GenServer.call(pid, :registered?, 5_000)
    end
  catch
    :exit, _reason -> false
  end

  @doc false
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @doc false
  @impl GenServer
  def init(_options) do
    {:ok, %{registered?: false, attempts: 0}, {:continue, :register}}
  end

  @doc false
  @impl GenServer
  # **BlueZ has to be told, and it has to be told after the object exists.** An agent
  # registered before the path answers is one BlueZ calls and gets nothing from.
  def handle_continue(:register, state) do
    with :ok <- serve(),
         {:ok, _answer} <-
           Bus.call(@manager_path, @manager_interface, "RegisterAgent", [@path, @capability]),
         {:ok, _default} <-
           Bus.call(@manager_path, @manager_interface, "RequestDefaultAgent", [@path]) do
      Logger.info("Bluetooth registered its pairing agent.")

      {:noreply, %{state | registered?: true}}
    else
      {:error, reason} ->
        {:noreply, again(state, reason)}
    end
  end

  # **The bus is up before it is connected.** `PiFi.Bluetooth.Bus` starts, the supervisor
  # moves on to this, and the connection is made in a continue of its own — so the first
  # attempt lands on a bus that answers `:not_connected`, and a board came up with no
  # agent at all. Waiting and asking again is what closes that gap.
  defp again(%{attempts: attempts} = state, _reason) when attempts < @attempts do
    Process.send_after(self(), :register, @retry)

    %{state | attempts: attempts + 1}
  end

  defp again(state, reason) do
    Logger.warning(
      "Bluetooth could not register a pairing agent: #{inspect(reason)}. " <>
        "Pairing will not finish."
    )

    state
  end

  @doc false
  @impl GenServer
  def handle_call(:registered?, _from, state), do: {:reply, state.registered?, state}

  @doc false
  @impl GenServer
  def handle_info(:register, state), do: handle_continue(:register, state)

  def handle_info({:dbus_method_call, message, connection}, state) do
    answer(:dbus_message.get_field(@member, message), message, connection)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp answer("Introspect", message, connection) do
    reply(connection, :dbus_message.return(message, [:string], [@introspection]))
  end

  defp answer(member, message, connection) when member in @approved do
    Logger.debug("Bluetooth agent approved #{member}.")

    reply(connection, :dbus_message.return(message, [], []))
  end

  defp answer(member, message, connection) when member in @refused do
    reply(
      connection,
      :dbus_message.error(message, :"org.bluez.Error.Rejected", "This device has no keypad.")
    )
  end

  defp answer(member, message, connection) do
    reply(
      connection,
      :dbus_message.error(
        message,
        :"org.freedesktop.DBus.Error.UnknownMethod",
        "The agent does not do #{member}."
      )
    )
  end

  defp reply(connection, message) do
    :dbus_connection.cast(connection, message)
  rescue
    exception -> Logger.warning("Bluetooth agent could not answer: #{inspect(exception)}")
  catch
    :exit, reason -> Logger.warning("Bluetooth agent could not answer: #{inspect(reason)}")
  end

  # **The library keeps one service for calls that name no exported name**, and a
  # message BlueZ sends back to this connection is one of those. It offers no accessor
  # for it, so the state of the registry is where it comes from.
  defp serve do
    with pid when is_pid(pid) <- Process.whereis(:dbus_service_reg),
         service when is_pid(service) <- :sys.get_state(pid) |> elem(1),
         :ok <- :dbus_service.register_object(service, @path, self()) do
      :ok
    else
      nil -> {:error, :no_service_registry}
      {:already_registered, _path} -> :ok
      other -> {:error, other}
    end
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc false
  @impl GenServer
  def terminate(_reason, %{registered?: true}) do
    Bus.call(@manager_path, @manager_interface, "UnregisterAgent", [@path])

    :ok
  end

  def terminate(_reason, _state), do: :ok
end
