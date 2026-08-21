defmodule MyHiFi.Output.UsbDacTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Output.UsbDac

  describe "parse_cards/1" do
    test "reads a USB DAC" do
      contents = """
       0 [Audio          ]: USB-Audio - SA9023 USB Audio
                            HiFimeDIY Audio SA9023 USB Audio at usb-3f980000.usb-1, full speed
      """

      assert [%{id: "Audio", title: "SA9023 USB Audio"}] = UsbDac.parse_cards(contents)
    end

    test "leaves out a card that is not USB audio" do
      contents = """
       0 [vc4hdmi        ]: vc4-hdmi - vc4-hdmi
                            vc4-hdmi
      """

      assert [] = UsbDac.parse_cards(contents)
    end

    test "reads more than one card, and keeps each USB one" do
      contents = """
       0 [vc4hdmi        ]: vc4-hdmi - vc4-hdmi
                            vc4-hdmi
       1 [Audio          ]: USB-Audio - SA9023 USB Audio
                            HiFimeDIY Audio SA9023 USB Audio at usb-1, full speed
       2 [Second         ]: USB-Audio - Another DAC
                            Another DAC at usb-2, high speed
      """

      assert [%{id: "Audio"}, %{id: "Second", title: "Another DAC"}] =
               UsbDac.parse_cards(contents)
    end

    test "gives nothing for an empty file" do
      assert [] = UsbDac.parse_cards("")
    end
  end

  describe "devices/0" do
    test "does not fail on a machine with no sound card" do
      assert is_list(UsbDac.devices())
    end
  end

  describe "sink_spec/1" do
    test "names a plughw device, so ALSA converts the format and the rate" do
      assert %MyHiFi.Output.APlaySink{device: "plughw:CARD=Audio,DEV=0"} =
               UsbDac.sink_spec("Audio")
    end
  end
end
