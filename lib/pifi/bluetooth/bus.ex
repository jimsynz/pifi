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
  @root "/"

  # A person has to press a button on a speaker for some of these, so the wait is theirs
  # and not the network's.
  @call_timeout :timer.seconds(60)

  # **The library gives up after five seconds and says nothing about it.**
  # `:dbus_proxy.call/4` uses a default of its own, so `@call_timeout` covered only the
  # call to this process and the one underneath it timed out first — a headset that was
  # waking up answered `Connect` in more than five, and the board reported a failure for
  # something that was still going. It is shorter than `@call_timeout` so that the
  # method's own answer is what a caller sees rather than a timeout on this process.
  @method_timeout :timer.seconds(55)

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{connection: term() | nil, proxies: %{optional(String.t()) => pid()}}

    defstruct connection: nil, proxies: %{}
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
  @spec objects(String.t()) :: {:ok, map()} | {:error, term()}
  def objects(service \\ @bluez) do
    case ask({:objects, service}, :timer.seconds(10)) do
      {:ok, answer} -> answer
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Call a method on one BlueZ object.

  `path` is an object path such as `/org/bluez/hci0`, `interface` names the interface
  that carries the method, and `arguments` is a list in the order the method takes them.

  **The timeout here is not the one that decides.** `dbus_peer_connection:call/2` waits
  five seconds for a reply and throws, and nothing a caller passes reaches that far
  down, so every method of BlueZ is capped at five seconds whatever this says. `Connect`
  to a headset waking from sleep takes longer, and the answer is a timeout for something
  that then succeeds a moment later — `PiFi.Bluetooth.Devices.connect/1` watches the
  device rather than believing it.
  """
  @spec call(String.t(), String.t(), String.t(), [term()]) :: {:ok, term()} | {:error, term()}
  def call(path, interface, method, arguments \\ []) do
    case ask({:call, path, interface, method, arguments}, @call_timeout) do
      {:ok, answer} -> answer
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Ask BlueZ to tell a process when something under `path` changes.

  **BlueZ says what happened and nothing else asks it to.** A headset that connects or
  goes away changes no file and raises no kernel event, so a part of this firmware that
  wanted to know had to poll — and `objects/0` is a round trip that reads every device
  BlueZ has ever seen.

  The watcher is sent `{:signal, sender, interface, member, path, arguments}` for
  anything under the namespace, which is every device of an adapter when the namespace
  is the adapter. Filtering is the watcher's, because the match that D-Bus takes is
  coarse and one subscription is cheaper than several.
  """
  @spec watch(String.t(), pid(), String.t()) :: :ok | {:error, term()}
  def watch(path, watcher \\ self(), service \\ @bluez) do
    case ask({:watch, service, path, watcher}) do
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

  @doc """
  Turn what the library answers into something a caller can read.

  It is public for the reason `PiFi.Bluetooth.Devices.parse/1` is: this is the whole of
  the reading, and a test should not need a bus to check it.

  **Most of what BlueZ does answers with nothing at all.** `Pair`, `Connect`,
  `StartDiscovery` and the rest are void methods, and `:dbus_proxy` answers a bare `:ok`
  for them rather than `{:ok, nil}`. Every caller reads `{:ok, _}`, so without this the
  whole of the device API raised on the path where it had worked — which is the state it
  was in until a real headset was put in front of it.

      iex> PiFi.Bluetooth.Bus.answered(:ok)
      {:ok, nil}

      iex> PiFi.Bluetooth.Bus.answered({:ok, "something"})
      {:ok, "something"}

  **A BlueZ error arrives as the death of the proxy that carried it.** The library's
  proxy is a `gen_server` and it answers an error by returning it from a callback, which
  is not a reply, so it stops with `bad_return_value` and the caller sees an exit. The
  name of the error is in there, buried two levels down, and it is the only part worth
  anything — so it is dug out rather than passed on as a wall of `GenServer.call`.

      iex> PiFi.Bluetooth.Bus.answered(
      ...>   {:error,
      ...>    {{:bad_return_value, {:"org.bluez.Error.InProgress", "Operation already in progress"}},
      ...>     {GenServer, :call, [self(), :whatever, 60_000]}}}
      ...> )
      {:error, {:"org.bluez.Error.InProgress", "Operation already in progress"}}

      iex> PiFi.Bluetooth.Bus.answered({:"org.bluez.Error.Failed", "No discovery started"})
      {:error, {:"org.bluez.Error.Failed", "No discovery started"}}

      iex> PiFi.Bluetooth.Bus.answered({:error, :not_connected})
      {:error, :not_connected}
  """
  @spec answered(term()) :: {:ok, term()} | {:error, term()}
  def answered(:ok), do: {:ok, nil}
  def answered({:ok, answer}), do: {:ok, answer}

  def answered({:error, {{:bad_return_value, {name, message}}, _call}}) do
    {:error, {name, message}}
  end

  def answered({:error, reason}), do: {:error, reason}

  def answered({name, message}) when is_atom(name) and is_binary(message),
    do: {:error, {name, message}}

  def answered(other), do: {:error, other}

  @doc false
  @impl GenServer
  def init(_options) do
    # **The library reads this once, when it authenticates.** Setting it here rather
    # than in `config/target.exs` keeps it beside the reason, and reads the uid rather
    # than assuming it.
    Application.put_env(:dbus, :external_cookie, external_cookie(uid()))
    System.put_env("DBUS_SYSTEM_BUS_ADDRESS", "unix:path=" <> @socket)

    # **A proxy that dies must not take this process with it.** `:dbus_proxy.start_link/3`
    # is the only way the library makes one, and a proxy stops with `bad_return_value`
    # whenever BlueZ answers with an error. Without this, one refused call kills the bus
    # connection — and BlueZ ends the discovery that connection started, so a scan
    # stops the first time anything goes wrong.
    Process.flag(:trap_exit, true)

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

  def handle_call({:objects, _service}, _from, %State{connection: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:objects, service}, _from, %State{} = state) do
    case proxy_for(service, root_of(service), state) do
      {:ok, proxy, state} ->
        {:reply, invoke(proxy, @object_manager, "GetManagedObjects", []), state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:call, _path, _interface, _method, _arguments},
        _from,
        %State{connection: nil} = state
      ) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:watch, _service, _path, _watcher}, _from, %State{connection: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  # **The subscription goes through the proxy of the path being watched.** `AddMatch`
  # belongs to the bus daemon and not to BlueZ, and the six-argument `connect_signal`
  # sends it to whatever the proxy points at — which answered
  # `Method "AddMatch" ... doesn't exist` from `org.bluez`. The two-argument one reaches
  # into the proxy for the bus connection and asks that instead, and it matches on the
  # proxy's own path as a namespace, which is every device of an adapter.
  def handle_call({:watch, service, path, watcher}, _from, %State{} = state) do
    case proxy_for(service, path, state) do
      {:ok, proxy, state} -> {:reply, subscribe(proxy, watcher), state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:call, path, interface, method, arguments}, _from, %State{} = state) do
    case proxy_for(path, state) do
      {:ok, proxy, state} -> {:reply, invoke(proxy, interface, method, arguments), state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @doc false
  @impl GenServer
  # **Trapping exits turns two very different deaths into the same message.** A proxy
  # stops with `bad_return_value` every time BlueZ answers with an error, and
  # `invoke/5` has already turned that into an answer for the caller. The connection
  # dying is the other one, and it has to be noticed: the library links each proxy to
  # the connection, so a refused call takes the bus down with it, and a process holding
  # a dead connection answers `:noproc` to everything for ever after.
  def handle_info({:EXIT, dead, reason}, %State{} = state) do
    if connection_pid(state.connection) == dead do
      Logger.warning("Bluetooth lost the system bus: #{inspect(reason)}. Connecting again.")

      {:noreply, %State{state | connection: connect(), proxies: %{}}}
    else
      {:noreply, %State{state | proxies: without(state.proxies, dead)}}
    end
  end

  def handle_info(_message, %State{} = state), do: {:noreply, state}

  # **The connection is not a bare pid.** `:dbus_bus_connection.connect/1` answers
  # `{:dbus_bus_connection, pid}`, and an earlier version of the clause above compared
  # the whole term against the pid in the exit — so it never matched, and the bus sat
  # holding a dead connection.
  defp connection_pid({:dbus_bus_connection, pid}) when is_pid(pid), do: pid
  defp connection_pid(pid) when is_pid(pid), do: pid
  defp connection_pid(_other), do: nil

  # A proxy stops whenever BlueZ answers with an error, so the one that died is dropped
  # and the next call for that object makes a fresh one.
  defp without(proxies, dead) do
    proxies |> Enum.reject(fn {_path, proxy} -> proxy == dead end) |> Map.new()
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

  defp subscribe(proxy, watcher) do
    :dbus_proxy.connect_signal(proxy, watcher)
  rescue
    exception -> {:error, exception}
  catch
    :throw, thrown -> answered(thrown)
    :exit, reason -> {:error, reason}
  end

  defp invoke(proxy, interface, method, arguments) do
    :dbus_proxy.call(proxy, interface, method, arguments, @method_timeout) |> answered()
  rescue
    exception -> {:error, exception}
  catch
    # **A BlueZ error is thrown, and the throw lands here rather than in the proxy.**
    # `:dbus_proxy.call/4` ends in `may_throw/1`, which throws the error in whatever
    # process called it. A `gen_server` treats a throw out of a callback as the value
    # that callback returned, so this process stopped with `bad_return_value` — taking
    # the bus connection with it, and with it every discovery BlueZ had tied to that
    # connection. That is why a scan reported `:ok` and then quietly ended.
    :throw, thrown -> answered(thrown)
    :exit, reason -> answered({:error, reason})
  end

  # **One proxy for each object, kept and used again.** Making one per call leaks a
  # process against this one every time, and stopping it after the call ends the
  # discovery BlueZ started on it — a scan that reported `:ok` and then found nothing.
  # So they are held here, and `handle_info/2` drops one that has died.
  # **BlueALSA answers `GetManagedObjects` on its own path and not on `/`.** BlueZ takes
  # the root, and asking BlueALSA there answers nothing at all.
  defp root_of(@bluez), do: @root
  defp root_of(_service), do: "/org/bluealsa"

  defp proxy_for(path, %State{} = state), do: proxy_for(@bluez, path, state)

  defp proxy_for(service, path, %State{} = state) do
    case Map.get(state.proxies, {service, path}) do
      proxy when is_pid(proxy) ->
        if Process.alive?(proxy),
          do: {:ok, proxy, state},
          else:
            make_proxy(
              service,
              path,
              %State{state | proxies: Map.delete(state.proxies, {service, path})}
            )

      nil ->
        make_proxy(service, path, state)
    end
  end

  defp make_proxy(service, path, %State{} = state) do
    case :dbus_proxy.start_link(state.connection, service, path) do
      {:ok, proxy} ->
        {:ok, proxy, %State{state | proxies: Map.put(state.proxies, {service, path}, proxy)}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end
end
