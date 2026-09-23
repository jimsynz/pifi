defmodule PiFi.Bluetooth.Devices do
  @moduledoc """
  The speakers and headphones that this device can see, and what it can do with them.

  BlueZ keeps one object for each adapter and one for each device it has heard of, and
  `PiFi.Bluetooth.Bus` reads them. This turns that into something a page can draw and a
  person can act on.

  ## Only the ones that can take audio, and the profile is not how to tell

  **A Bluetooth adapter sees telephones, watches, keyboards and beacons.** None of those
  is a speaker, and a list that offered them would ask a person to tell them apart by
  name — which for a device advertising as `48-35-A9-2C-D7-7A` they cannot.

  The obvious filter is the A2DP Sink profile, and **it does not work**. A board found
  five devices and reported this for each of them:

      "UUIDs" => [], "ServicesResolved" => false

  BlueZ learns the profiles of a device by asking it, and it asks when something pairs
  or connects. Before that the list is empty, so a filter on it hides every device a
  person could pair with and leaves them nothing to press.

  What does arrive with the inquiry is the class of device, which every BR/EDR device
  carries, and the icon BlueZ derives from it. So the filter is: the class says audio,
  or the icon says audio, or the profiles are known and include A2DP Sink. The last one
  covers a speaker that is already paired, where the profiles are the better answer.

  **A device with no class at all is not a candidate**, and that is a rule rather than a
  guess: A2DP is a BR/EDR profile, and a device that advertises only over Bluetooth Low
  Energy cannot carry it. That is what removes the watches and the beacons.

  ## Discovery is where the devices live

  **BlueZ forgets a device that nobody paired with**, shortly after discovery stops. A
  board listed five while discovery ran and none a minute later. So a page that offers
  pairing has to keep discovery going while a person is looking, and a list taken after
  it stops shows the paired ones alone.

  ## Pairing and trusting are two different things

  `Pair` is the exchange that agrees a key. `Trusted` is a property this firmware sets
  afterwards, and without it BlueZ asks for authorisation every time the speaker comes
  back — which for a speaker that a person turns on in the morning is every morning. A
  device this firmware paired is one a person chose, so it is trusted when the pairing
  finishes.

  ## It reads the bus rather than keeping a list

  BlueZ already holds this. A copy here would go stale the moment a speaker was turned
  off, and the copy is what a person would be reading.
  """

  alias PiFi.Bluetooth.Bus

  @adapter_interface "org.bluez.Adapter1"
  @device_interface "org.bluez.Device1"
  @properties "org.freedesktop.DBus.Properties"

  # **A device that can receive audio advertises this.** It is "Audio Sink" of the
  # Bluetooth assigned numbers, and a speaker, a pair of headphones and a car stereo all
  # carry it. See <https://www.bluetooth.com/specifications/assigned-numbers/>.
  @a2dp_sink "0000110b-0000-1000-8000-00805f9b34fb"

  # Audio/Video, of the major device classes. See the Bluetooth assigned numbers.
  @audio_major_class 0x04

  @typedoc """
  One speaker or pair of headphones.

  `path` is the object that BlueZ keeps it under, and every call names it. `address` is
  what `bluealsa` opens, which is why it is kept beside the name a person reads.
  """
  @type device :: %{
          path: String.t(),
          address: String.t(),
          name: String.t(),
          paired?: boolean(),
          connected?: boolean(),
          trusted?: boolean()
        }

  @doc """
  The A2DP Sink profile, which is what says a device can take audio.

      iex> PiFi.Bluetooth.Devices.audio_profile()
      "0000110b-0000-1000-8000-00805f9b34fb"
  """
  @spec audio_profile() :: String.t()
  def audio_profile, do: @a2dp_sink

  @doc """
  Every device that can take audio, newest answer first.
  """
  @spec list() :: {:ok, [device()]} | {:error, term()}
  def list do
    with {:ok, objects} <- Bus.objects() do
      {:ok, parse(objects)}
    end
  end

  @doc """
  Turn what BlueZ reported into the devices worth showing.

  It is public because it is the whole of the reading, and a test should not need a bus
  to check it.

      iex> PiFi.Bluetooth.Devices.parse(%{
      ...>   "/org/bluez/hci0" => %{"org.bluez.Adapter1" => %{}},
      ...>   "/org/bluez/hci0/dev_11_22_33_44_55_66" => %{
      ...>     "org.bluez.Device1" => %{
      ...>       "Address" => "11:22:33:44:55:66",
      ...>       "Alias" => "Kitchen Speaker",
      ...>       "Paired" => true,
      ...>       "Connected" => false,
      ...>       "Trusted" => true,
      ...>       "UUIDs" => ["0000110b-0000-1000-8000-00805f9b34fb"]
      ...>     }
      ...>   }
      ...> })
      [%{path: "/org/bluez/hci0/dev_11_22_33_44_55_66", address: "11:22:33:44:55:66",
         name: "Kitchen Speaker", paired?: true, connected?: false, trusted?: true}]
  """
  @spec parse(map()) :: [device()]
  def parse(objects) do
    objects
    |> Enum.flat_map(fn
      {path, %{@device_interface => properties}} -> List.wrap(device(path, properties))
      _other -> []
    end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  The adapter, if this device has one.

  A board with no Bluetooth at all reports none, and every control above this is then
  drawn as unavailable rather than as broken.
  """
  @spec adapter() ::
          {:ok, %{path: String.t(), powered?: boolean(), discovering?: boolean()}} | :error
  def adapter do
    case Bus.objects() do
      {:ok, objects} -> Enum.find_value(objects, :error, &found_adapter/1)
      {:error, _reason} -> :error
    end
  end

  defp found_adapter({path, %{@adapter_interface => properties}}) do
    {:ok,
     %{
       path: path,
       powered?: Map.get(properties, "Powered", false),
       discovering?: Map.get(properties, "Discovering", false)
     }}
  end

  defp found_adapter(_object), do: nil

  @doc """
  Look for speakers.

  BlueZ stops on its own after a while, and `stop_discovery/0` stops it sooner. A
  discovery that is already running answers `:ok`.
  """
  @spec discover() :: :ok | {:error, term()}
  def discover do
    case adapter() do
      {:ok, %{path: path}} -> started(path, Bus.call(path, @adapter_interface, "StartDiscovery"))
      :error -> {:error, :no_adapter}
    end
  end

  defp started(path, answer, clear? \\ true)

  defp started(_path, {:ok, _answer}, _clear?), do: :ok

  # **BlueZ says a scan is running when there is none.** A board reported
  # `InProgress` while the adapter's own `Discovering` read false, and the
  # `StopDiscovery` that followed answered `No discovery started` — the two halves of
  # bluetoothd disagreeing with each other. It happens after whatever asked for the
  # last scan went away without ending it, and the session is stuck until something
  # clears it. So this believes the adapter rather than the answer: if it really is
  # scanning, asking twice is not a failure, and if it is not, the phantom is cleared
  # and a fresh scan started.
  defp started(path, {:error, {:"org.bluez.Error.InProgress", _message}} = answer, clear?) do
    case {adapter(), clear?} do
      {{:ok, %{discovering?: true}}, _clear?} ->
        :ok

      # Once. A daemon that says this twice is one nothing here can talk round, and
      # clearing it again would be a loop rather than a recovery.
      {_otherwise, true} ->
        Bus.call(path, @adapter_interface, "StopDiscovery")

        started(path, Bus.call(path, @adapter_interface, "StartDiscovery"), false)

      {_otherwise, false} ->
        {:error, elem(answer, 1)}
    end
  end

  defp started(_path, {:error, reason}, _clear?), do: {:error, reason}

  @doc "Stop looking."
  @spec stop_discovery() :: :ok | {:error, term()}
  def stop_discovery do
    case adapter() do
      {:ok, %{path: path}} -> stopped(Bus.call(path, @adapter_interface, "StopDiscovery"))
      :error -> {:error, :no_adapter}
    end
  end

  # A scan that was not running is one that is stopped, which is what the caller wanted.
  defp stopped({:ok, _answer}), do: :ok
  defp stopped({:error, {:"org.bluez.Error.Failed", "No discovery started"}}), do: :ok
  defp stopped({:error, reason}), do: {:error, reason}

  @doc """
  Pair with one device, and trust it.

  **The trust is the half that a person notices.** Pairing agrees a key once, and
  without trust BlueZ asks for authorisation every time the speaker comes back. A
  speaker that a person paired on purpose is one they mean to keep.

  It can take a while: some speakers want a button pressed, and the call waits for it.
  """
  @spec pair(String.t()) :: :ok | {:error, term()}
  def pair(path) do
    case Bus.call(path, @device_interface, "Pair") do
      {:ok, _answer} -> trust(path)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Mark a device as one this firmware may talk to without asking again.
  """
  @spec trust(String.t()) :: :ok | {:error, term()}
  def trust(path) do
    # **`Set` takes a variant, and a variant is a record and not a pair.** A board
    # answered `Invalid signature for 'Trusted'` for `{:boolean, true}`: the pairing had
    # already worked, and only the trust that follows it failed.
    trusted = {:dbus_variant, :boolean, true}

    case Bus.call(path, @properties, "Set", [@device_interface, "Trusted", trusted]) do
      {:ok, _answer} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Open the audio connection to a paired device."
  @spec connect(String.t()) :: :ok | {:error, term()}
  def connect(path), do: acted(Bus.call(path, @device_interface, "Connect"))

  @doc "Close it."
  @spec disconnect(String.t()) :: :ok | {:error, term()}
  def disconnect(path), do: acted(Bus.call(path, @device_interface, "Disconnect"))

  @doc """
  Forget a device, so that BlueZ asks to pair again next time.
  """
  @spec forget(String.t()) :: :ok | {:error, term()}
  def forget(path) do
    case adapter() do
      # **`RemoveDevice` takes a plain object path and not a tagged one.** The library
      # reads the signature out of the introspection and marshals the string itself, so
      # `{:object_path, path}` gave `InvalidParameters "o"`. Only `Set` needs a tag,
      # because only `Set` takes a variant.
      {:ok, %{path: adapter}} ->
        acted(Bus.call(adapter, @adapter_interface, "RemoveDevice", [path]))

      :error ->
        {:error, :no_adapter}
    end
  end

  defp acted({:ok, _answer}), do: :ok
  defp acted({:error, reason}), do: {:error, reason}

  # **A device with no name is one that answered its address and nothing else.** The
  # address is what it is, so that is what a person reads until it says more.
  defp device(path, properties) do
    if audio?(properties) do
      address = Map.get(properties, "Address")

      %{
        path: path,
        address: address,
        name: name(properties, address),
        paired?: Map.get(properties, "Paired", false),
        connected?: Map.get(properties, "Connected", false),
        trusted?: Map.get(properties, "Trusted", false)
      }
    end
  end

  # **The class of device is what arrives with the inquiry**, and the profiles are what
  # arrive after something asks. A speaker that nobody has paired with has the first and
  # not the second. See the module documentation for the measurement.
  defp audio?(properties) do
    advertises_audio?(properties) or audio_class?(properties) or audio_icon?(properties)
  end

  defp advertises_audio?(properties) do
    properties
    |> Map.get("UUIDs", [])
    |> Enum.any?(&(String.downcase(to_string(&1)) == @a2dp_sink))
  end

  # Bits 12 to 8 of the class are the major device class, and 4 is Audio/Video. A pair
  # of headphones reports `0x240414`, and `(0x240414 >>> 8) &&& 0x1F` is 4.
  defp audio_class?(%{"Class" => class}) when is_integer(class) do
    import Bitwise

    (class >>> 8 &&& 0x1F) == @audio_major_class
  end

  defp audio_class?(_properties), do: false

  # BlueZ derives this from the class, and it is the friendlier half of the same fact:
  # `audio-headset`, `audio-headphones`, `audio-card`.
  defp audio_icon?(%{"Icon" => icon}) when is_binary(icon),
    do: String.starts_with?(icon, "audio-")

  defp audio_icon?(_properties), do: false

  defp name(properties, address) do
    case Map.get(properties, "Alias") || Map.get(properties, "Name") do
      name when is_binary(name) and name != "" -> name
      _other -> address
    end
  end
end
