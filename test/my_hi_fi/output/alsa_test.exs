defmodule MyHiFi.Output.AlsaTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Output.Alsa

  describe "parse_cards/1" do
    test "reads a USB DAC" do
      contents = """
       0 [Audio          ]: USB-Audio - SA9023 USB Audio
                            HiFimeDIY Audio SA9023 USB Audio at usb-3f980000.usb-1, full speed
      """

      assert [%{number: 0, id: "Audio", title: "SA9023 USB Audio", usb?: true}] =
               Alsa.parse_cards(contents)
    end

    test "keeps a card that is not USB audio" do
      contents = """
       0 [vc4hdmi        ]: vc4-hdmi - vc4-hdmi
                            vc4-hdmi
      """

      assert [%{number: 0, id: "vc4hdmi", usb?: false}] = Alsa.parse_cards(contents)
    end

    # `MyHiFi.Player` uses the first device when the chosen one is absent. A target
    # with HDMI audio therefore still uses the DAC.
    test "puts each USB card before every other card, and keeps the order of ALSA" do
      contents = """
       0 [vc4hdmi        ]: vc4-hdmi - vc4-hdmi
                            vc4-hdmi
       1 [Audio          ]: USB-Audio - SA9023 USB Audio
                            HiFimeDIY Audio SA9023 USB Audio at usb-1, full speed
       2 [Second         ]: USB-Audio - Another DAC
                            Another DAC at usb-2, high speed
      """

      assert [%{id: "Audio"}, %{id: "Second"}, %{id: "vc4hdmi"}] = Alsa.parse_cards(contents)
    end

    test "gives nothing for an empty file" do
      assert [] = Alsa.parse_cards("")
    end
  end

  describe "parse_pcm/1" do
    test "reads the number and the name of a playback device" do
      contents = """
      card: 1
      device: 0
      subdevice: 0
      stream: PLAYBACK
      id: ALC255 Analog
      name: ALC255 Analog
      subname: subdevice #0
      class: 0
      subclass: 0
      subdevices_count: 1
      subdevices_avail: 1
      """

      assert %{device: 0, name: "ALC255 Analog"} = Alsa.parse_pcm(contents)
    end

    test "reads a device that is not the first of its card" do
      contents = """
      card: 0
      device: 7
      stream: PLAYBACK
      name: HDMI 1
      """

      assert %{device: 7, name: "HDMI 1"} = Alsa.parse_pcm(contents)
    end

    test "gives nothing for a device that records" do
      contents = """
      card: 1
      device: 0
      stream: CAPTURE
      name: ALC255 Analog
      """

      assert Alsa.parse_pcm(contents) == nil
    end

    test "gives nothing for text that holds no device" do
      assert Alsa.parse_pcm("") == nil
    end
  end

  describe "devices/0" do
    test "does not fail on a machine with no sound card" do
      assert is_list(Alsa.devices())
    end

    test "names a device that ALSA can open" do
      for device <- Alsa.devices() do
        assert device.id =~ ~r/\Ahw:CARD=\S+,DEV=\d+\z/
        assert is_binary(device.title)
      end
    end
  end

  describe "sink_spec/1" do
    test "adds the plug layer, so ALSA converts the format and the rate" do
      assert %MyHiFi.Output.APlaySink{device: "plughw:CARD=Audio,DEV=0"} =
               Alsa.sink_spec("hw:CARD=Audio,DEV=0")
    end
  end
end
