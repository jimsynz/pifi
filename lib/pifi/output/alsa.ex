defmodule PiFi.Output.Alsa do
  @moduledoc """
  A sound card, through ALSA.

  The Nerves system ships `alsa-lib`, `aplay` and `amixer`, and no other audio
  software. `membrane_alsa_plugin` does not exist. `PiFi.Output.APlaySink`
  therefore writes the samples to an `aplay` port, and this module finds the
  hardware and names it.

  It lists every card, and not the USB cards alone. A USB DAC is what this device
  plays through, and an I2S DAC on the GPIO header is an ALSA card as well. The
  host of a developer has a card, and a person can now choose it and hear the
  audio while they work.

  It lists a playback device of a card, and not the card. A card has none, one,
  or several, and `aplay` opens a device. One HD-Audio card of a laptop has the
  devices 3, 7, 8 and 9 for HDMI and no device 0, so a name that ends in
  `DEV=0` cannot open on it.

  A device of a USB card comes first in the list. `PiFi.Player` uses the first
  device when the chosen one is absent, so a target with HDMI audio still uses the
  DAC.

  The target needs a custom Nerves system, because the stock `rpi0_2` system ships
  no USB host stack and no USB audio class driver.
  """

  @behaviour PiFi.Output

  alias PiFi.Bluetooth.Devices

  # Sobelow reads `@sobelow_skip` from the source. This registration stops the
  # compiler warning that no Elixir code reads the attribute.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @cards_path "/proc/asound/cards"
  @card_path "/proc/asound/card"
  @usb_driver "USB-Audio"

  # **The loopback is a pipe between two programs and not a thing to listen to.**
  # `snd-aloop` presents a card like any other, and the settings page reads this list,
  # so a person would be offered "Loopback" beside their DAC and the music would go
  # into the capture side that Spotify reads from. See `PiFi.Spotify.Loopback`.
  @hidden_cards ["Loopback"]

  @doc """
  List each playback device that ALSA knows about.

  It reads `/proc/asound`, so it runs no command. It returns an empty list when that
  directory is absent, so a machine with no sound card gives no error.
  """
  @impl PiFi.Output
  def devices do
    Enum.flat_map(cards(), &playback_devices/1) ++ bluetooth()
  end

  # **A paired headset is an ALSA device like any other**, which is the whole reason
  # Bluetooth fits this firmware: `bluez-alsa` installs a userspace plugin, so a speaker
  # is a PCM name and nothing in the player or the sink learns a word about it.
  #
  # **What counts is whether BlueALSA has a PCM, and not what BlueZ believes.** A headset
  # that was switched off loses its PCM at once and stays `Connected` to BlueZ for about
  # twenty seconds, so a list built on the second one offers a device that cannot be
  # opened. `PiFi.Bluetooth.Devices.playable/0` says why that matters to the player.
  #
  # BlueZ is still asked, for the name: BlueALSA knows the address and not what a person
  # calls the thing.
  defp bluetooth do
    with {:ok, addresses} <- Devices.playable(),
         {:ok, devices} <- Devices.list() do
      for %{address: address} = device <- devices, address in addresses do
        %{id: bluetooth_id(address), title: device.name}
      end
    else
      {:error, _reason} -> []
    end
  end

  @doc """
  The ALSA name of one paired Bluetooth device.

      iex> PiFi.Output.Alsa.bluetooth_id("70:BF:92:04:AC:5A")
      "bluealsa:DEV=70:BF:92:04:AC:5A,PROFILE=a2dp"
  """
  @spec bluetooth_id(String.t()) :: String.t()
  def bluetooth_id(address), do: "bluealsa:DEV=#{address},PROFILE=a2dp"

  @doc """
  Give a sink that plays to one device.

  The `id` of a device is its ALSA hardware name, which begins `hw:`. **No card ever
  gets that name, because `hw:` converts nothing.** A USB card gets the `rate48`
  definition of `/etc/asound.conf`, and every other card gets `plughw:`. Both hold the
  `plug` layer, and the rate is the only difference between them.

  **The sample format of the decoder is not a choice, and a card refuses what it does
  not hold.** `Membrane.RawAudio` calls 24 bits in 3 bytes `:s24le`, and ALSA calls the
  same thing `S24_3LE`. libmad gives that for every MP3. The PCM5102A of a Pirate Audio
  offers `S16_LE`, `S24_LE` and `S32_LE`, and `S24_LE` is 24 bits in 4 bytes, so none of
  the three is what arrives. `aplay` therefore stopped at once, the port write gave
  `:epipe`, and the pipeline of every track died with
  `{:membrane_child_crash, :sink, :epipe}`. A measurement on the board on 2026-09-01
  showed `S24_3LE` refused on `hw:` and played on `plughw:`.

  The USB DAC hid this. `rate48` names the `plug` layer, so that card converted the
  format from the first day, and only a card that reached `hw:` could show the fault.

  **The rate is not a preference, and it is not a fact about every card.** USB audio
  sends one isochronous packet in each 1 ms frame, so 44100 Hz needs 44.1 samples in a
  packet and a controller must alternate the size of them. The dwc2 controller of this
  board handles that badly. A 440 Hz tone straight to `aplay` on 2026-08-24 was rough
  at 44100 Hz and clean at 24000 Hz and at 48000 Hz, and the level of the tone decided
  nothing. Almost every podcast is 44100 Hz MP3, and both RNZ streams are 24000 Hz,
  so internet radio never met this.

  The fault is in the USB controller of the board, so it reaches USB cards and no
  other kind. A card on the I2S pins plays 44100 Hz as it arrives, and forcing 48000 Hz
  there would resample every podcast for no reason.

  `:alsa_rate48?` says whether the definition is there to name. `rootfs_overlay` ships
  it, so a target build has it and a host does not. Naming a definition that no
  configuration names gives `Unknown PCM rate48:...` and no sound at all.
  """
  @impl PiFi.Output
  def sink_spec(device_id) do
    %PiFi.Output.APlaySink{device: pcm_name(device_id)}
  end

  @doc """
  The name that ALSA takes for one card.

  `sink_spec/1` wraps this in a Membrane sink, and a program that is not Membrane
  needs the name on its own: `PiFi.Spotify` hands it to librespot, which opens ALSA
  itself and knows nothing about the pipeline of this firmware.

  **It carries the `rate48` of a USB card**, which this board needs and which
  `plug/1` explains, so a program that takes this name plays at the rate that the
  card is held at rather than the rate that the audio arrived at.

      iex> PiFi.Output.Alsa.pcm_name("hw:CARD=Audio,DEV=0")
      "plughw:CARD=Audio,DEV=0"

  **A Bluetooth device goes through as it is, and that is not an oversight.** It looks
  like the `hw:` trap — A2DP carries SBC in `S16_LE` and libmad gives `S24_3LE` for
  every MP3 — but the definition `bluez-alsa` ships is already `type plug` over a
  `type bluealsa` slave, so the conversion is there before this sees it. A board played
  `S24_3LE` straight to `bluealsa:DEV=...` and `aplay` exited 0.

  **Wrapping it again does not work in any case.** `plug:` reads what follows as
  arguments, so `plug:bluealsa:DEV=...` gives `Unknown parameter bluealsa:DEV`, and only
  a quoted slave name parses. There is nothing to gain by quoting it.

      iex> PiFi.Output.Alsa.pcm_name("bluealsa:DEV=70:BF:92:04:AC:5A,PROFILE=a2dp")
      "bluealsa:DEV=70:BF:92:04:AC:5A,PROFILE=a2dp"
  """
  @spec pcm_name(String.t()) :: String.t()
  def pcm_name(device_id) do
    String.replace_prefix(device_id, "hw:", plug(device_id))
  end

  # `plughw:` is a device of ALSA itself, so it needs no definition and a host has it
  # as well. `rate48` is ours, and `:alsa_rate48?` says whether the configuration that
  # says that it is there to name: naming a definition that no configuration has gives
  # `Unknown PCM rate48:...` and no sound at all.
  defp plug(device_id), do: if(forced_48k?(device_id), do: "rate48:", else: "plughw:")

  defp forced_48k?(device_id) do
    Application.get_env(:pifi, :alsa_rate48?, false) and usb?(device_id)
  end

  # The identifier carries the name of the card, and `/proc/asound/cards` says which
  # driver owns it.
  defp usb?(device_id) do
    case Regex.run(~r/CARD=([^,]+)/, device_id) do
      [_whole, name] -> Enum.any?(cards(), &(&1.id == name and &1.usb?))
      nil -> false
    end
  end

  defp cards do
    case File.read(@cards_path) do
      {:ok, contents} -> parse_cards(contents)
      {:error, _reason} -> []
    end
  end

  @doc """
  Read the cards that this firmware offers, from the text of `/proc/asound/cards`.

  **A card of `@hidden_cards` is not one of them.** The loopback is a pipe between two
  programs, and dropping it here rather than at the caller means no part of this module
  can offer it by accident.

  Each card takes two lines. The first carries the number, the identifier, the
  driver and a short name. The second carries a longer description.

      ` 0 [Audio          ]: USB-Audio - SA9023 USB Audio`
      `                      HiFimeDIY Audio SA9023 USB Audio at usb-1, full speed`

  A card of a USB DAC comes first, and the order of ALSA stands inside each group.
  """
  @spec parse_cards(String.t()) :: [
          %{number: integer(), id: String.t(), title: String.t(), usb?: boolean()}
        ]
  def parse_cards(contents) do
    ~r/^\s*(?<number>\d+)\s+\[(?<id>\S+)\s*\]:\s*(?<driver>\S+)\s+-\s+(?<title>.+)$/m
    |> Regex.scan(contents, capture: :all_names)
    |> Enum.map(fn [driver, id, number, title] ->
      %{
        number: String.to_integer(number),
        id: id,
        title: String.trim(title),
        usb?: driver == @usb_driver
      }
    end)
    |> Enum.reject(&(&1.id in @hidden_cards))
    |> Enum.sort_by(&(not &1.usb?))
  end

  @doc """
  Read the number of a playback device from the text of one `pcm` info file.

  It returns `nil` for a device that records, because a person cannot play to a
  microphone.

      `card: 1`
      `device: 0`
      `stream: PLAYBACK`
      `name: ALC255 Analog`
  """
  @spec parse_pcm(String.t()) :: %{device: integer(), name: String.t()} | nil
  def parse_pcm(contents) do
    fields =
      ~r/^(?<key>\w+):\s*(?<value>.*)$/m
      |> Regex.scan(contents, capture: :all_names)
      |> Map.new(fn [key, value] -> {key, String.trim(value)} end)

    with %{"stream" => "PLAYBACK", "device" => device, "name" => name} <- fields,
         {device, ""} <- Integer.parse(device) do
      %{device: device, name: name}
    else
      _other -> nil
    end
  end

  # The name of a device is what `aplay` opens, and it is what the settings hold.
  # The title names the card and the device, because one card has more than one.
  #
  # No path here comes from a person. `Path.wildcard/1` gives each name, and the
  # pattern names the number of a card that `/proc/asound/cards` gave.
  @sobelow_skip ["Traversal.FileModule"]
  defp playback_devices(card) do
    "#{@card_path}#{card.number}/pcm*p/info"
    |> Path.wildcard()
    |> Enum.map(&File.read/1)
    |> Enum.flat_map(fn
      {:ok, contents} -> List.wrap(parse_pcm(contents))
      {:error, _reason} -> []
    end)
    |> Enum.sort_by(& &1.device)
    |> Enum.map(fn pcm ->
      %{
        id: "hw:CARD=#{card.id},DEV=#{pcm.device}",
        title: title(card, pcm)
      }
    end)
  end

  defp title(%{title: card_title}, %{name: name}) do
    if String.contains?(card_title, name), do: card_title, else: "#{card_title}, #{name}"
  end

  @doc """
  Whether one card has a level that this firmware can set.

  **A DAC of a stereo often has none.** A measurement on 2026-09-09 gave no mixer
  control at all for the PCM5102A of a Pirate Audio board, and one control named `PCM`
  for the HiFimeDIY SA9023 USB DAC of the other board. The first chip gives a fixed
  output on purpose, and a person with one sets the level on their amplifier.
  """
  @impl PiFi.Output
  def volume?(device_id), do: control(device_id) != nil

  @doc """
  Set the level of one card.

  **`-M` and not a raw number.** Without it `amixer` reads a percentage as a share of
  the range of the register, and the ear does not hear that way. With it the number is
  a share of the loudness, which is what a person moving a control means.

  **A read of the card cannot hold the number that a person chose.** A measurement on
  2026-09-09 set 60 percent on the USB DAC and read 59 back, because the range of that
  card has 111 steps and no step lands on every percentage.
  `PiFi.Output.Volume` therefore keeps what the person chose and this only writes it.
  """
  @impl PiFi.Output
  def put_volume(device_id, percent) when percent in 0..100 do
    with {:ok, card, name, index} <- mixer(device_id) do
      case System.cmd("amixer", ["-c", card, "-M", "sset", "#{name},#{index}", "#{percent}%"],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:amixer, status, String.trim(output)}}
      end
    end
  rescue
    error in ErlangError -> {:error, {:amixer, error}}
  end

  @doc """
  Read the controls from the text of `amixer scontents`.

  One call names every control of a card and the capabilities of each one, so this
  needs no second call for each control.

      `Simple mixer control 'PCM',0`
      `  Capabilities: pvolume pswitch pswitch-joined`

  **`pvolume` is the capability that matters**, and it says that the control sets a
  playback level. A control of a capture level names `cvolume`, and one that only mutes
  names `pswitch` alone.
  """
  @spec parse_scontents(String.t()) :: [%{name: String.t(), index: integer()}]
  def parse_scontents(contents) do
    ~r/^Simple mixer control '(?<name>[^']+)',(?<index>\d+)\n(?<body>(?:[ \t].*\n?)*)/m
    |> Regex.scan(contents, capture: :all_names)
    |> Enum.filter(fn [body, _index, _name] -> playback_volume?(body) end)
    |> Enum.map(fn [_body, index, name] ->
      %{name: name, index: String.to_integer(index)}
    end)
  end

  defp playback_volume?(body) do
    case Regex.run(~r/^\s*Capabilities:\s*(?<caps>.*)$/m, body, capture: :all_names) do
      [caps] -> "pvolume" in String.split(caps)
      nil -> false
    end
  end

  # **The order is the one that a person means by "the volume".** A card with
  # `Master` sets the level of the whole card there, and `PCM` is the level of the
  # stream. A card with one of the two names it one of these ways, and the
  # USB DAC of the measurement has `PCM` and no `Master`.
  #
  # A card that names none of them still has a level, so the first control with a
  # playback level is better than nothing.
  @preferred ~w[Master PCM Speaker Headphone]

  defp control(device_id) do
    case mixer(device_id) do
      {:ok, _card, name, index} -> %{name: name, index: index}
      {:error, _reason} -> nil
    end
  end

  defp mixer(device_id) do
    with {:ok, card} <- card_name(device_id),
         {:ok, controls} <- scontents(card),
         %{name: name, index: index} <- preferred(controls) do
      {:ok, card, name, index}
    else
      nil -> {:error, :no_volume_control}
      {:error, reason} -> {:error, reason}
    end
  end

  defp preferred([]), do: nil

  defp preferred(controls) do
    Enum.find(@preferred, &Enum.find(controls, fn control -> control.name == &1 end))
    |> case do
      nil -> hd(controls)
      name -> Enum.find(controls, &(&1.name == name))
    end
  end

  # `amixer` takes the identifier of a card as well as its number, so the name that the
  # settings hold needs no lookup of the number.
  defp card_name(device_id) do
    case Regex.run(~r/CARD=([^,]+)/, device_id) do
      [_whole, name] -> {:ok, name}
      nil -> {:error, :not_a_card}
    end
  end

  defp scontents(card) do
    case System.cmd("amixer", ["-c", card, "scontents"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, parse_scontents(output)}
      {_output, _status} -> {:error, :no_such_card}
    end
  rescue
    error in ErlangError -> {:error, {:amixer, error}}
  end
end
