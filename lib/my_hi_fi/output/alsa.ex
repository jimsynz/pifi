defmodule MyHiFi.Output.Alsa do
  @moduledoc """
  A sound card, through ALSA.

  The Nerves system holds `alsa-lib`, `aplay` and `amixer`, and no other audio
  software. `membrane_alsa_plugin` does not exist. `MyHiFi.Output.APlaySink`
  therefore writes the samples to an `aplay` port, and this module finds the
  hardware and names it.

  It lists every card, and not the USB cards alone. A USB DAC is what this device
  plays through, and an I2S DAC on the GPIO header is an ALSA card as well. The
  host of a developer holds a card, and a person can now choose it and hear the
  audio while they work.

  It lists a playback device of a card, and not the card. A card holds none, one,
  or several, and `aplay` opens a device. One HD-Audio card of a laptop holds the
  devices 3, 7, 8 and 9 for HDMI and holds no device 0, so a name that ends in
  `DEV=0` cannot open on it.

  A device of a USB card comes first in the list. `MyHiFi.Player` uses the first
  device when the chosen one is absent, so a target with HDMI audio still uses the
  DAC.

  The target needs a custom Nerves system, because the stock `rpi0_2` system holds
  no USB host stack and no USB audio class driver.
  """

  @behaviour MyHiFi.Output

  # Sobelow reads `@sobelow_skip` from the source. This registration stops the
  # compiler warning that no Elixir code reads the attribute.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @cards_path "/proc/asound/cards"
  @card_path "/proc/asound/card"
  @usb_driver "USB-Audio"

  @doc """
  List each playback device that ALSA knows about.

  It reads `/proc/asound`, so it runs no command. It gives an empty list when that
  directory is absent, so a machine with no sound card gives no error.
  """
  @impl MyHiFi.Output
  def devices do
    Enum.flat_map(cards(), &playback_devices/1)
  end

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

  The USB DAC hid this. `rate48` holds the `plug` layer, so that card converted the
  format from the first day, and only a card that reached `hw:` could show the fault.

  **The rate is not a preference, and it is not a fact about every card.** USB audio
  sends one isochronous packet in each 1 ms frame, so 44100 Hz needs 44.1 samples in a
  packet and a controller must alternate the size of them. The dwc2 controller of this
  board handles that badly. A 440 Hz tone straight to `aplay` on 2026-08-24 was rough
  at 44100 Hz and clean at 24000 Hz and at 48000 Hz, and the level of the tone decided
  nothing. Almost every podcast holds 44100 Hz MP3, and both RNZ streams hold 24000 Hz,
  so internet radio never met this.

  The fault is in the USB controller of the board, so it reaches USB cards and no
  other kind. A card on the I2S pins plays 44100 Hz as it arrives, and forcing 48000 Hz
  there would resample every podcast for no reason.

  `:alsa_rate48?` says whether the definition is there to name. `rootfs_overlay` holds
  it, so a target build has it and a host does not. Naming a definition that no
  configuration holds gives `Unknown PCM rate48:...` and no sound at all.
  """
  @impl MyHiFi.Output
  def sink_spec(device_id) do
    %MyHiFi.Output.APlaySink{device: String.replace_prefix(device_id, "hw:", plug(device_id))}
  end

  # `plughw:` is a device of ALSA itself, so it needs no definition and a host holds it
  # as well. `rate48` is ours, and `:alsa_rate48?` says whether the configuration that
  # holds it is there to name: naming a definition that no configuration holds gives
  # `Unknown PCM rate48:...` and no sound at all.
  defp plug(device_id), do: if(forced_48k?(device_id), do: "rate48:", else: "plughw:")

  defp forced_48k?(device_id) do
    Application.get_env(:my_hi_fi, :alsa_rate48?, false) and usb?(device_id)
  end

  # The identifier holds the name of the card, and `/proc/asound/cards` says which
  # driver holds it.
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
  Read the cards from the text of `/proc/asound/cards`.

  Each card takes two lines. The first holds the number, the identifier, the
  driver and a short name. The second holds a longer description.

      ` 0 [Audio          ]: USB-Audio - SA9023 USB Audio`
      `                      HiFimeDIY Audio SA9023 USB Audio at usb-1, full speed`

  A card of a USB DAC comes first, and the order of ALSA holds inside each group.
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
    |> Enum.sort_by(&(not &1.usb?))
  end

  @doc """
  Read the number of a playback device from the text of one `pcm` info file.

  It gives `nil` for a device that records, because a person cannot play to a
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
  # The title names the card and the device, because one card holds more than one.
  #
  # No path here comes from a person. `Path.wildcard/1` gives each name, and the
  # pattern holds the number of a card that `/proc/asound/cards` gave.
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
end
