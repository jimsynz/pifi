defmodule PiFi.Bluetooth.Monitor do
  @moduledoc """
  Starts the player when a telephone sends, and stops it when the telephone goes.

  `PiFi.Bluetooth.Watcher` is the other half of this pair and watches the other
  direction: it hears a *speaker* arrive and tells `PiFi.Player` that the outputs
  changed. This hears a *telephone* arrive and tells the player to play it, which is
  what `PiFi.Spotify.Monitor` does for a cast.

  ## bluez-alsa says nothing, so this asks

  **BlueZ signals and bluez-alsa does not.** `PiFi.Bluetooth.Watcher` records that
  bluez-alsa implements `GetManagedObjects` and not the `InterfacesAdded` that would
  say when the answer changed, so a PCM appearing raises no signal anywhere. BlueZ does
  signal `Connected` for the device, and that is the thing to hang this on — but it
  arrives before the transport exists, which the watcher also found: a board reported
  `Connected` three seconds before bluez-alsa had the PCM.

  So a `Connected` starts a short poll rather than a play. The poll is what makes the
  difference between a telephone that plays and one that connects and sits there.

  ## Only a telephone that this device is playing may stop it

  A disconnect that arrived while a person was listening to a podcast would take their
  music away. This is the rule `PiFi.Spotify.Monitor` follows for the same reason, and
  it is checked against the source of what is playing rather than against anything this
  process remembers.

  ## It runs whether the radio does or not, and that is what lets it start the radio

  **A person turns this source on under Settings → Sources, and the radio may be off.**
  Nothing else would turn it on: `PiFi.Playback.enable_source/2` is the generic switch
  and knows nothing about any source, which is what `PiFi.Source` exists to keep true.
  So this is a child of the application and not of `PiFi.Bluetooth`, because a monitor
  that only ran while the daemons did could not be the thing that starts them.
  `PiFi.Spotify.Monitor` does the same job for the same reason.

  **Turning the source off leaves the radio alone.** The radio is shared: a person
  listening on Bluetooth headphones has `PiFi.Output.Alsa` pointed at it, and stopping
  the daemons would take their music away to tidy up a switch they did not touch. So
  this starts and never stops.
  """

  use GenServer

  require Logger

  alias PiFi.Bluetooth.Sender
  alias PiFi.Event
  alias PiFi.Event.Source.EnabledChanged
  alias PiFi.Player
  alias PiFi.Source

  @properties "org.freedesktop.DBus.Properties"
  @device_interface "org.bluez.Device1"
  @connected "Connected"

  # **BlueZ says connected before bluez-alsa has the PCM.** Six seconds of asking, a
  # second apart, covers the three a board measured with room for a telephone that is
  # slower.
  @settle 1_000
  @settle_attempts 6

  @doc false
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @doc false
  @impl GenServer
  def init(_options) do
    :ok = Event.subscribe(:source)

    {:ok, %{attempts: 0}}
  end

  @doc """
  Hear about a device that changed on the bus.

  `PiFi.Bluetooth.Watcher` holds the subscriptions, because the library matches a
  namespace in a way that only an exact path works for and one subscription for each
  paired device is what that costs. It hands a connection change here rather than this
  process subscribing to the same paths again.
  """
  @spec connection_changed() :: :ok
  def connection_changed do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, :connection_changed)
    end
  end

  @doc false
  @impl GenServer
  def handle_cast(:connection_changed, state) do
    {:noreply, look(state)}
  end

  @doc false
  @impl GenServer
  def handle_info(:look, state), do: {:noreply, look(state)}

  # **A person who turns this on and finds nothing has been told nothing.** The radio is
  # what a telephone pairs with, so turning the source on turns it on. A board that has
  # no adapter is left alone, because no daemon will change that.
  def handle_info(%EnabledChanged{source: Source.Bluetooth, enabled?: true}, state) do
    started_the_radio()

    {:noreply, state}
  end

  # A person turning this source off while a telephone is playing means the music
  # stops, in the way that it does for Spotify. **The radio stays on**: it is shared
  # with the headphones a person may be listening to. See the module documentation.
  def handle_info(%EnabledChanged{source: Source.Bluetooth, enabled?: false}, state) do
    if playing?(), do: Player.stop()

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  Whether a signal is one that says a device came or went.

  `PiFi.Bluetooth.Watcher` reads the same shape for its own purpose, and this is
  public so the test of either one can build a signal that is real rather than
  assumed.

      iex> PiFi.Bluetooth.Monitor.connection_signal?(
      ...>   "org.freedesktop.DBus.Properties",
      ...>   "PropertiesChanged",
      ...>   {"org.bluez.Device1", %{"Connected" => true}, []}
      ...> )
      true

      iex> PiFi.Bluetooth.Monitor.connection_signal?(
      ...>   "org.freedesktop.DBus.Properties",
      ...>   "PropertiesChanged",
      ...>   {"org.bluez.MediaControl1", %{"Connected" => true}, []}
      ...> )
      false
  """
  @spec connection_signal?(term(), term(), term()) :: boolean()
  def connection_signal?(interface, member, {on, changed, _invalidated}) do
    to_string(interface) == @properties and to_string(member) == "PropertiesChanged" and
      to_string(on) == @device_interface and is_map(changed) and
      Map.has_key?(changed, @connected)
  end

  def connection_signal?(_interface, _member, _arguments), do: false

  # **A telephone that went is the other half of this, and it is the same look.**
  # `Sender.playing/0` answers `nil` once bluez-alsa drops the PCM, so a connect and a
  # disconnect are one question asked at the same moments.
  defp look(state) do
    case {Sender.playing(), playing?()} do
      {%{} = sender, false} -> started(sender, state)
      {nil, true} -> stopped(state)
      {nil, false} -> settled(state)
      {_sender, _playing?} -> %{state | attempts: 0}
    end
  end

  defp started(sender, state) do
    if Source.enabled?(Source.Bluetooth) do
      case Player.play(Source.Bluetooth.item()) do
        :ok ->
          Logger.info("A telephone at #{sender.address} is playing over Bluetooth.")

        {:error, reason} ->
          Logger.warning("A telephone did not reach the player: #{inspect(reason)}")
      end
    end

    %{state | attempts: 0}
  end

  defp stopped(state) do
    Player.stop()

    %{state | attempts: 0}
  end

  # Nothing changed yet, so ask again until the transport has had time to arrive.
  defp settled(%{attempts: attempts} = state) when attempts < @settle_attempts do
    Process.send_after(self(), :look, @settle)

    %{state | attempts: attempts + 1}
  end

  defp settled(state), do: %{state | attempts: 0}

  defp started_the_radio do
    cond do
      PiFi.Bluetooth.enabled?() ->
        :ok

      not PiFi.Bluetooth.adapter?() ->
        Logger.info("Bluetooth is a source now, and this board has no adapter.")

      true ->
        told(PiFi.Bluetooth.enable(true))
    end
  end

  defp told(:ok), do: Logger.info("Bluetooth is a source now, so the radio is on.")

  defp told({:error, reason}),
    do:
      Logger.warning("Bluetooth is a source now and the radio did not start: #{inspect(reason)}")

  defp playing?, do: match?(%{source: Source.Bluetooth}, PiFi.Playback.state!())
end
