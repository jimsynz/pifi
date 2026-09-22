defmodule PiFi.Bluetooth.Bus do
  @moduledoc """
  The connection to the system bus, and the one place that talks to BlueZ.

  **BlueZ speaks D-Bus and nothing else.** There is no command to drive it with and no
  socket of its own: pairing, the list of devices and every property of an adapter come
  over the bus. `PiFi.Bluetooth` starts the daemons and this talks to them.

  ## The uid is the whole of the authentication

  `dbus_auth_external` sends the uid of the connecting process, hex encoded, and the bus
  compares it against the credentials it reads off the socket itself. The library ships
  a constant:

      -define(cookie, <<"31303030">>).

  That is hex for `1000`. **A Nerves device runs the BEAM as root**, so the claim and
  the credentials disagreed, EXTERNAL failed, and the fallback ran down through
  `DBUS_COOKIE_SHA1` to `ANONYMOUS`, which a system bus refuses. A board reported that
  as a connection that hung and said nothing about why.

  So this sets the cookie from `uid/0` rather than trusting either the library's
  constant or the fact that Nerves happens to run as root. The uid is a fact the
  firmware can read, and reading it costs nothing.

  ## It holds the connection open

  A connection is a process, and BlueZ publishes changes on it: a device that came
  within range, a pairing that finished, a headset that went away. A caller that opened
  a connection for each question would hear none of that, so this holds one and the
  parts above it ask through it.
  """

  use GenServer

  require Logger

  @bus :system
  @socket "/run/dbus/system_bus_socket"
  @bluez "org.bluez"
  @object_manager "org.freedesktop.DBus.ObjectManager"

  # A person has to press a button on a speaker for some of these, so the wait is theirs
  # and not the network's.
  @call_timeout :timer.seconds(60)

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{connection: term() | nil}

    defstruct connection: nil
  end

  @doc false
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @doc """
  The hex-encoded uid that the EXTERNAL mechanism sends.

  It is the decimal uid as text, hex encoded, which is what the D-Bus specification
  asks for. Root is `"0"`, so `"30"`.

      iex> PiFi.Bluetooth.Bus.external_cookie(0)
      "30"

      iex> PiFi.Bluetooth.Bus.external_cookie(1000)
      "31303030"
  """
  @spec external_cookie(non_neg_integer()) :: String.t()
  def external_cookie(uid) do
    uid
    |> to_string()
    |> Base.encode16(case: :lower)
  end

  @doc """
  The uid of this process.

  **OTP has no call for this**, so it comes from `/proc/self/status`, which is where
  Linux keeps it and which costs no process to read. A machine without that file gets
  0, which is what a Nerves device is in any case: the fallback is wrong only on a
  laptop, where nothing here connects to a bus.
  """
  @spec uid() :: non_neg_integer()
  def uid do
    with {:ok, status} <- File.read("/proc/self/status"),
         [_line, found] <- Regex.run(~r/^Uid:\s+(\d+)/m, status),
         {number, _rest} <- Integer.parse(found) do
      number
    else
      _other -> 0
    end
  end

  @doc """
  Whether the bus is reachable now.
  """
  @spec connected?() :: boolean()
  def connected?, do: match?({:ok, true}, ask(:connected?))

  @doc """
  Everything that BlueZ knows about, by object path.

  `/org/bluez/hci0` is an adapter and `/org/bluez/hci0/dev_XX_XX_XX_XX_XX_XX` is a
  device it has seen. Each one carries the interfaces it offers and their properties.
  """
  @spec objects() :: {:ok, map()} | {:error, term()}
  def objects do
    case ask(:objects, :timer.seconds(10)) do
      {:ok, answer} -> answer
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Call a method on one BlueZ object.

  `path` is an object path such as `/org/bluez/hci0`, `interface` names the interface
  that carries the method, and `arguments` is a list in the order the method takes them.

  **The timeout is long on purpose.** `Pair` waits for a person to press a button on a
  speaker, and `StartDiscovery` answers at once but `Connect` does not: a call that gave
  up after five seconds would report a failure for a pairing that was still going.
  """
  @spec call(String.t(), String.t(), String.t(), [term()]) :: {:ok, term()} | {:error, term()}
  def call(path, interface, method, arguments \\ []) do
    case ask({:call, path, interface, method, arguments}, @call_timeout) do
      {:ok, answer} -> answer
      {:error, reason} -> {:error, reason}
    end
  end

  # **Bluetooth is off on a device that nobody asked for it, and off is not a crash.**
  # A page that lists speakers runs whether the daemons do or not, and a `GenServer.call`
  # to a process that is not there exits the caller rather than answering it.
  defp ask(message, timeout \\ 5_000) do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      pid -> {:ok, GenServer.call(pid, message, timeout)}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @doc false
  @impl GenServer
  def init(_options) do
    # **The library reads this once, when it authenticates.** Setting it here rather
    # than in `config/target.exs` keeps it beside the reason, and reads the uid rather
    # than assuming it.
    Application.put_env(:dbus, :external_cookie, external_cookie(uid()))
    System.put_env("DBUS_SYSTEM_BUS_ADDRESS", "unix:path=" <> @socket)

    {:ok, %State{}, {:continue, :connect}}
  end

  @doc false
  @impl GenServer
  def handle_continue(:connect, %State{} = state) do
    {:noreply, %State{state | connection: connect()}}
  end

  @doc false
  @impl GenServer
  def handle_call(:connected?, _from, %State{} = state) do
    {:reply, not is_nil(state.connection), state}
  end

  def handle_call(:objects, _from, %State{connection: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:objects, _from, %State{} = state) do
    {:reply, managed_objects(state.connection), state}
  end

  def handle_call(
        {:call, _path, _interface, _method, _arguments},
        _from,
        %State{connection: nil} = state
      ) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:call, path, interface, method, arguments}, _from, %State{} = state) do
    {:reply, invoke(state.connection, path, interface, method, arguments), state}
  end

  # **A bus that is not there is not an error worth stopping for.** The daemons start
  # beside this one and the socket appears when `dbus-daemon` is ready, so a connection
  # that failed is a reason to say so and carry on: `PiFi.Bluetooth` restarts the group
  # when the bus goes, and nothing above this can do anything with a crash here.
  defp connect do
    case :dbus_bus_connection.connect(@bus) do
      {:ok, connection} ->
        Logger.info("Bluetooth reached the system bus.")

        connection

      other ->
        Logger.warning("Bluetooth did not reach the system bus: #{inspect(other)}")

        nil
    end
  rescue
    exception ->
      Logger.warning("Bluetooth did not reach the system bus: #{Exception.message(exception)}")

      nil
  catch
    :exit, reason ->
      Logger.warning("Bluetooth did not reach the system bus: #{inspect(reason)}")

      nil
  end

  defp invoke(connection, path, interface, method, arguments) do
    with {:ok, proxy} <- :dbus_proxy.start_link(connection, @bluez, path) do
      :dbus_proxy.call(proxy, interface, method, arguments)
    end
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end

  defp managed_objects(connection) do
    with {:ok, proxy} <- :dbus_proxy.start_link(connection, @bluez, "/"),
         {:ok, objects} <- :dbus_proxy.call(proxy, @object_manager, "GetManagedObjects", []) do
      {:ok, objects}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end
end
