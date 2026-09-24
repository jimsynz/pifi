defmodule PiFi.Bluetooth.Watcher do
  @moduledoc """
  Tells the rest of the firmware when a headset arrives or goes.

  **A Bluetooth device changes the list of outputs and the kernel says nothing.**
  `PiFi.Device.Monitor` hears a sound card being plugged in because a uevent arrives;
  `bluealsa` is an ALSA plugin in userspace, so a headset connecting produces no uevent
  and no event. `PiFi.Output.Alsa.devices/0` quietly started answering differently and
  nothing noticed.

  Two things went wrong on a board because of it. Turning a headset off moved the music
  to the USB DAC, because `PiFi.Player` falls back to the first device it can find. And
  turning it back on left the music on the DAC while the settings page still showed the
  headset — the page was not wrong, it was told nothing.

  So this listens to BlueZ instead and calls `PiFi.Player.outputs_changed/0`, which
  publishes the event and decides what to do about the audio.

  ## One subscription for each paired device, and not one for the adapter

  Watching the adapter's whole path would be cheaper and it does not work. The library
  matches a namespace with

      match_path({P, true}, NS) -> lists:prefix(filename:split(NS), filename:split(P)).

  where `P` is the namespace that was registered and `NS` is the path the signal came
  from — so it asks whether the incoming path is a prefix of the namespace, which is
  backwards. `/org/bluez/hci0` matches itself and every `/org/bluez/hci0/dev_…` under it
  is dropped. A board subscribed to the adapter, saw the adapter's own `Discovering`
  change, and heard nothing at all about any headset.

  An exact path matches on the clause above it and works, so this follows each paired
  device instead. There are few of them, and a device nobody paired cannot be an output.

  **`PropertiesChanged` says only what changed.** A signal that carries no `Connected`
  is a battery level or a name, and it is ignored rather than read for a field that is
  absent.
  """

  use GenServer

  require Logger

  alias PiFi.Bluetooth.Bus
  alias PiFi.Bluetooth.Devices
  alias PiFi.Player

  @properties "org.freedesktop.DBus.Properties"
  @device_interface "org.bluez.Device1"
  @connected "Connected"

  # The bus connects in a continue of its own, so the first attempt is often too early.
  @attempts 10
  @retry 1_000

  # Long enough for BlueALSA to have the PCM that BlueZ has already promised.
  @settle 6_000

  # **A connect to a device that is switched off takes about twenty seconds to fail**,
  # because `PiFi.Bluetooth.Devices.connect/1` waits out the five second cap the library
  # imposes and then watches the device. Thirty leaves ten seconds of quiet between
  # attempts; anything shorter overlaps with itself.
  @reconnect :timer.seconds(30)

  @doc false
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @doc false
  @impl GenServer
  def init(_options), do: {:ok, %{watching?: false, attempts: 0}, {:continue, :watch}}

  @doc false
  @impl GenServer
  def handle_continue(:watch, state) do
    case paired() do
      {:ok, paths} ->
        for path <- paths, do: Bus.watch(path, self())

        Logger.info("Bluetooth is listening to #{length(paths)} paired device(s).")

        Process.send_after(self(), :reconnect, @reconnect)

        {:noreply, %{state | watching?: true}}

      {:error, reason} ->
        {:noreply, again(state, reason)}
    end
  end

  defp paired do
    case Devices.list() do
      {:ok, devices} -> {:ok, devices |> Enum.filter(& &1.paired?) |> Enum.map(& &1.path)}
      {:error, reason} -> {:error, reason}
    end
  end

  # **The bus is up before it is connected**, so the first attempt lands on one that
  # answers `:not_connected`. See the same guard in `PiFi.Bluetooth.Agent`.
  defp again(%{attempts: attempts} = state, _reason) when attempts < @attempts do
    Process.send_after(self(), :watch, @retry)

    %{state | attempts: attempts + 1}
  end

  defp again(state, reason) do
    Logger.warning(
      "Bluetooth cannot hear devices arrive: #{inspect(reason)}. " <>
        "The list of outputs will go stale."
    )

    state
  end

  @doc """
  Listen to one more device, which is what a fresh pairing is.

  A device that pairs after this started is one nothing is listening to yet, and the
  first thing a person does with it is play something.
  """
  @spec follow(String.t()) :: :ok
  def follow(path) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:follow, path})
    end
  end

  @doc false
  @impl GenServer
  def handle_cast({:follow, path}, state) do
    Bus.watch(path, self())

    {:noreply, state}
  end

  @doc "Whether BlueZ is telling this about its devices."
  @spec watching?() :: boolean()
  def watching? do
    case GenServer.whereis(__MODULE__) do
      nil -> false
      pid -> GenServer.call(pid, :watching?, 5_000)
    end
  catch
    :exit, _reason -> false
  end

  @doc false
  @impl GenServer
  def handle_call(:watching?, _from, state), do: {:reply, state.watching?, state}

  @doc false
  @impl GenServer
  def handle_info(:watch, state), do: handle_continue(:watch, state)

  # **Nothing else goes looking for a headset that was switched off.** The resume in
  # `PiFi.Player` only fires when a device comes back, and this Jabra does not come back
  # on its own — a person is left with a paused track and no way forward but the
  # settings page.
  def handle_info(:reconnect, state) do
    Process.send_after(self(), :reconnect, @reconnect)

    reach_for_the_waited_on()

    {:noreply, state}
  end

  def handle_info({:signal, _sender, interface, member, _path, arguments}, state) do
    if connection_changed?(interface, member, arguments), do: told()

    {:noreply, state}
  end

  def handle_info(:again, state) do
    Player.outputs_changed()

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # **It reaches only while something is waiting**, which is the whole of the policy:
  # a paused track whose output went, a device that is awake, and Bluetooth on. A radio
  # that reached at any other time would be poking at a headset in a drawer.
  #
  # **The connect does not run here.** It takes about twenty seconds for a device that
  # is switched off, and this process carries the signals that say a device arrived —
  # twenty seconds of those queueing behind it is twenty seconds of a page not knowing.
  defp reach_for_the_waited_on do
    with true <- PiFi.Bluetooth.enabled?(),
         chosen when is_binary(chosen) <- Player.waiting_for_output(),
         {:ok, device} <- absent_device(chosen) do
      Task.start(fn -> Devices.connect(device.path) end)
    else
      _otherwise -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  # A paired device that BlueALSA has no PCM for is one worth reaching for. Anything
  # else is either here already or not ours to connect.
  defp absent_device(chosen) do
    with {:ok, playable} <- Devices.playable(),
         {:ok, devices} <- Devices.list(),
         %{} = device <-
           Enum.find(devices, &(&1.paired? and String.contains?(chosen, &1.address))),
         false <- device.address in playable do
      {:ok, device}
    else
      _otherwise -> :none
    end
  end

  # **BlueZ says a device is connected before there is anything to play to.** A board
  # reported `Connected` three seconds before BlueALSA had the PCM, so a player that
  # looked once looked too early and stayed paused with the headset sitting there
  # working. BlueALSA would be the better thing to ask and it answers no signals at all:
  # it implements `GetManagedObjects` and not the `InterfacesAdded` that would say when
  # the answer changed. So this asks twice.
  defp told do
    Player.outputs_changed()

    Process.send_after(self(), :again, @settle)
  end

  # `PropertiesChanged` carries the interface it is about, the properties that changed,
  # and the names of those that were merely dropped. Only a device that came or went
  # matters here.
  defp connection_changed?(interface, member, arguments) do
    to_string(interface) == @properties and to_string(member) == "PropertiesChanged" and
      changed_connected?(arguments)
  end

  # **The body arrives as a tuple and not a list.** `{interface, changed, invalidated}`
  # is what a board reported, and a clause written for a list matched none of it — the
  # subscription worked, the signals arrived, and every one was quietly dropped.
  defp changed_connected?({on, changed, _invalidated}) do
    to_string(on) == @device_interface and is_map(changed) and
      Map.has_key?(changed, @connected)
  end

  # **`MediaControl1` carries a `Connected` of its own** and it is a different thing:
  # it says whether the remote control of a player is up, not whether the device is.
  # Reading it as the device's would report a headset gone while it was still playing.
  defp changed_connected?(_arguments), do: false
end
