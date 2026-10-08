defmodule PiFi.Bluetooth.Sender do
  @moduledoc """
  The telephone sending audio to this device, and the window in which one can find it.

  `PiFi.Bluetooth.Devices` is the other end of the same radio: it lists the speakers
  this device can play *to*. This is what a telephone sees when it looks for a speaker,
  and what it hands over once it has found one.

  **The profile is the whole of the difference.** `bluealsad` takes `a2dp-source` to
  send audio and `a2dp-sink` to take it, and `PiFi.Bluetooth` gives it both, so one
  daemon serves a pair of headphones and a telephone at the same time.

  ## A stereo is not discoverable, except when a person asks

  A device that advertised itself all the time is one anyone within ten metres can pair
  with, and a stereo lives in a room that people walk through. So `Discoverable` is a
  window with a timeout rather than a setting: a person opens it on the settings page,
  BlueZ closes it by itself, and nothing has to remember to.

  `Pairable` goes with it. The two are separate properties and either one alone is
  useless — a device that can be seen and not paired with, or one that can be paired
  with and not found.

  **The timeout belongs to BlueZ and not to a timer here.** A process that closed the
  window would have to survive a restart, a reboot and a person turning Bluetooth off
  halfway through, and `DiscoverableTimeout` already does all three.

  ## What bluez-alsa calls the telephone

  bluez-alsa names a PCM by the local profile and the direction the application reads
  it in, so a speaker this device plays to is `…/a2dpsrc/sink` and a telephone this
  device listens to is `…/a2dpsnk/source`. The ALSA name is the same either way —
  `bluealsa:DEV=<address>,PROFILE=a2dp` — because `arecord` asking for capture is what
  picks the direction.

  ## The rate is read and never assumed

  **A2DP negotiates the rate with the telephone.** Most send 44100 Hz and some send
  48000 Hz, and `PiFi.Player.CaptureSource` has to be told which: naming 44100 for a
  sender that agreed 48000 plays the audio 8.8% slow, which is the same mistake
  `rate48` of `/etc/asound.conf` exists to stop at the other end of the player.

  bluez-alsa publishes the agreed rate and channel count on the PCM object, so this
  reads them rather than guessing. A PCM that says neither is skipped, because a stream
  played at a guessed rate is worse than one that does not start.
  """

  alias PiFi.Bluetooth.Bus

  @bluealsa "org.bluealsa"
  @adapter_interface "org.bluez.Adapter1"
  @properties "org.freedesktop.DBus.Properties"
  @pcm_interface "org.bluealsa.PCM1"

  # What bluez-alsa puts in the path of a PCM that a telephone is playing into. See the
  # module documentation.
  @sink_profile "a2dpsnk"

  # How long a person gets to find this device on their telephone. Long enough to pick
  # up the telephone, open the settings and read a list, and short enough that a person
  # who walked away is not leaving the radio open.
  @window 120

  @typedoc """
  One telephone that is sending, or could.

  `device` is the ALSA name to capture, and `sample_rate` and `channels` are what the
  two ends agreed on.
  """
  @type sender :: %{
          address: String.t(),
          device: String.t(),
          sample_rate: pos_integer(),
          channels: pos_integer()
        }

  @doc """
  How long the window stays open, in seconds.

      iex> PiFi.Bluetooth.Sender.window()
      120
  """
  @spec window() :: pos_integer()
  def window, do: @window

  @doc """
  The ALSA name that captures a telephone at `address`.

      iex> PiFi.Bluetooth.Sender.capture_device("AA:BB:CC:DD:EE:FF")
      "bluealsa:DEV=AA:BB:CC:DD:EE:FF,PROFILE=a2dp"
  """
  @spec capture_device(String.t()) :: String.t()
  def capture_device(address), do: "bluealsa:DEV=#{address},PROFILE=a2dp"

  @doc """
  The telephones that bluez-alsa has a capture PCM for.

  **This is the question worth asking, and whether BlueZ calls a device connected is
  not.** A telephone that walks out of range drops its transport at once and bluez-alsa
  loses the PCM with it, while BlueZ goes on reporting `Connected` for about twenty
  seconds. `PiFi.Bluetooth.Devices.playable/0` says the same thing about the other
  direction and for the same reason.
  """
  @spec list() :: {:ok, [sender()]} | {:error, term()}
  def list do
    with {:ok, objects} <- Bus.objects(@bluealsa) do
      {:ok, parse(objects)}
    end
  end

  @doc """
  The telephones in a map of bluez-alsa objects.

  It is public so a test can read the shape without a bus.

      iex> PiFi.Bluetooth.Sender.parse(%{
      ...>   "/org/bluealsa/hci0/dev_AA_BB_CC_DD_EE_FF/a2dpsnk/source" => %{
      ...>     "org.bluealsa.PCM1" => %{"Sampling" => 48_000, "Channels" => 2}
      ...>   }
      ...> })
      [%{
        address: "AA:BB:CC:DD:EE:FF",
        device: "bluealsa:DEV=AA:BB:CC:DD:EE:FF,PROFILE=a2dp",
        sample_rate: 48_000,
        channels: 2
      }]
  """
  @spec parse(map()) :: [sender()]
  def parse(objects) do
    objects |> Enum.flat_map(&sending/1) |> Enum.uniq_by(& &1.address)
  end

  @doc """
  The one telephone to play, or `nil`.

  A telephone that two people cast to at once is not a case this device has: the sound
  card plays one thing, so the first of them is the one that plays.
  """
  @spec playing() :: sender() | nil
  def playing do
    case list() do
      {:ok, [sender | _rest]} -> sender
      _otherwise -> nil
    end
  end

  @doc """
  Let a telephone find this device, for `seconds`.

  `Pairable` and `Discoverable` are set together, and BlueZ closes both when the
  timeout runs out. See the module documentation.
  """
  @spec open_window(pos_integer()) :: :ok | {:error, term()}
  def open_window(seconds \\ @window) do
    with {:ok, %{path: path}} <- adapter(),
         :ok <- put(path, "DiscoverableTimeout", {:dbus_variant, :uint32, seconds}),
         :ok <- put(path, "PairableTimeout", {:dbus_variant, :uint32, seconds}),
         :ok <- put(path, "Pairable", {:dbus_variant, :boolean, true}) do
      put(path, "Discoverable", {:dbus_variant, :boolean, true})
    end
  end

  @doc "Close it again, before the timeout does."
  @spec close_window() :: :ok | {:error, term()}
  def close_window do
    with {:ok, %{path: path}} <- adapter(),
         :ok <- put(path, "Pairable", {:dbus_variant, :boolean, false}) do
      put(path, "Discoverable", {:dbus_variant, :boolean, false})
    end
  end

  @doc "Whether a telephone can find this device now."
  @spec discoverable?() :: boolean()
  def discoverable? do
    match?({:ok, %{discoverable?: true}}, adapter())
  end

  @doc """
  The adapter, with the two properties this module writes.

  It is the same object `PiFi.Bluetooth.Devices.adapter/0` reads, and the properties
  are different ones, so each module asks for what it uses.
  """
  @spec adapter() :: {:ok, %{path: String.t(), discoverable?: boolean()}} | {:error, term()}
  def adapter do
    with {:ok, objects} <- Bus.objects() do
      case Enum.find_value(objects, &found_adapter/1) do
        nil -> {:error, :no_adapter}
        adapter -> {:ok, adapter}
      end
    end
  end

  defp found_adapter({path, %{@adapter_interface => properties}}) do
    %{path: to_string(path), discoverable?: Map.get(properties, "Discoverable", false)}
  end

  defp found_adapter(_object), do: nil

  defp put(path, property, value) do
    case Bus.call(path, @properties, "Set", [@adapter_interface, property, value]) do
      {:ok, _answer} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # `/org/bluealsa/hci0/dev_70_BF_92_04_AC_5A/a2dpsnk/source` names the telephone in the
  # path and the agreed format in the properties.
  defp sending({path, interfaces}) do
    path = to_string(path)

    with true <- String.contains?(path, "/#{@sink_profile}/"),
         %{} = properties <- Map.get(interfaces, @pcm_interface),
         [_whole, address] <- Regex.run(~r/dev_([0-9A-F_]{17})/, path),
         rate when is_integer(rate) and rate > 0 <- Map.get(properties, "Sampling"),
         channels when is_integer(channels) and channels > 0 <-
           Map.get(properties, "Channels") do
      address = String.replace(address, "_", ":")

      [
        %{
          address: address,
          device: capture_device(address),
          sample_rate: rate,
          channels: channels
        }
      ]
    else
      _otherwise -> []
    end
  end
end
