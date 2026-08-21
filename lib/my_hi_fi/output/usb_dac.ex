defmodule MyHiFi.Output.UsbDac do
  @moduledoc """
  A USB DAC, through ALSA.

  The Nerves system holds `alsa-lib`, `aplay` and `amixer`, and no other audio
  software. `membrane_alsa_plugin` does not exist. `MyHiFi.Output.APlaySink`
  therefore writes the samples to an `aplay` port, and this module finds the card
  and names it.

  The target needs a custom Nerves system, because the stock `rpi0_2` system holds
  no USB host stack and no USB audio class driver.
  """

  @behaviour MyHiFi.Output

  @cards_path "/proc/asound/cards"
  @usb_driver "USB-Audio"

  @doc """
  List each USB audio card that ALSA knows about.

  It reads `/proc/asound/cards`. It gives an empty list when that file is absent,
  so a machine with no sound card gives no error.
  """
  @impl MyHiFi.Output
  def devices do
    case File.read(@cards_path) do
      {:ok, contents} -> parse_cards(contents)
      {:error, _reason} -> []
    end
  end

  @doc """
  Give a sink that plays to one card.

  The device string uses `plughw`, so ALSA converts the sample format and the
  sample rate when the DAC accepts neither. A DAC at full speed on USB often
  accepts fewer rates than a decoder gives.
  """
  @impl MyHiFi.Output
  def sink_spec(device_id) do
    %MyHiFi.Output.APlaySink{device: "plughw:CARD=#{device_id},DEV=0"}
  end

  @doc """
  Read the cards from the text of `/proc/asound/cards`.

  Each card takes two lines. The first holds the number, the identifier, the
  driver and a short name. The second holds a longer description.

      ` 0 [Audio          ]: USB-Audio - SA9023 USB Audio`
      `                      HiFimeDIY Audio SA9023 USB Audio at usb-1, full speed`

  Only a card with the `USB-Audio` driver is a USB DAC.
  """
  @spec parse_cards(String.t()) :: [MyHiFi.Output.device()]
  def parse_cards(contents) do
    ~r/^\s*\d+\s+\[(?<id>\S+)\s*\]:\s*(?<driver>\S+)\s+-\s+(?<title>.+)$/m
    |> Regex.scan(contents, capture: :all_names)
    |> Enum.map(fn [driver, id, title] ->
      %{driver: driver, id: id, title: String.trim(title)}
    end)
    |> Enum.filter(&(&1.driver == @usb_driver))
    |> Enum.map(&Map.take(&1, [:id, :title]))
  end
end
