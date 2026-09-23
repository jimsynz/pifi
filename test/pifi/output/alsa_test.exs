defmodule PiFi.Output.AlsaTest do
  use ExUnit.Case, async: true

  alias PiFi.Output.Alsa

  describe "parse_cards/1" do
    # **The loopback is a pipe between two programs and not a thing to listen to.** A
    # person offered it would send the music into the side that Spotify reads from. See
    # `PiFi.Spotify.Loopback`.
    test "the loopback card is not one a person can choose" do
      contents = """
       0 [Audio          ]: USB-Audio - SA9023 USB Audio
                            HiFimeDIY Audio SA9023 USB Audio at usb-1, full speed
       1 [Loopback       ]: Loopback - Loopback
                            Loopback 1
      """

      cards = Alsa.parse_cards(contents)

      assert [%{id: "Audio"}] = cards
      refute Enum.any?(cards, &(&1.id == "Loopback"))
    end

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

    # `PiFi.Player` uses the first device when the chosen one is absent. A target
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
        assert device.id =~ ~r/\Ahw:CARD=\S+,DEV=\d+\z/ or device.id =~ ~r/\Abluealsa:DEV=/
        assert is_binary(device.title)
      end
    end

    # A host runs no `bluealsa`, so the list is the cards alone and asking costs nothing.
    test "a machine with no Bluetooth lists its cards and no more" do
      refute Enum.any?(Alsa.devices(), &(&1.id =~ "bluealsa"))
    end
  end

  # **A headset is an ALSA device like any other**, which is the whole reason Bluetooth
  # fits: nothing in the player or the sink learns a word about it.
  describe "a Bluetooth device" do
    test "is named the way bluealsa names it" do
      assert Alsa.bluetooth_id("70:BF:92:04:AC:5A") ==
               "bluealsa:DEV=70:BF:92:04:AC:5A,PROFILE=a2dp"
    end

    # It looks like the `hw:` trap and it is not one: the definition `bluez-alsa` ships
    # is already `type plug` over a `type bluealsa` slave, so a board played `S24_3LE`
    # straight to it. Wrapping it again gives `Unknown parameter bluealsa:DEV`.
    test "goes through as it is, whatever the rate setting says" do
      for rate48? <- [true, false] do
        Application.put_env(:pifi, :alsa_rate48?, rate48?)

        assert Alsa.pcm_name("bluealsa:DEV=70:BF:92:04:AC:5A,PROFILE=a2dp") ==
                 "bluealsa:DEV=70:BF:92:04:AC:5A,PROFILE=a2dp"
      end

      Application.delete_env(:pifi, :alsa_rate48?)
    end

    test "gets a sink that names the PCM bluealsa offers" do
      assert %PiFi.Output.APlaySink{device: "bluealsa:DEV=70:BF:92:04:AC:5A,PROFILE=a2dp"} =
               Alsa.sink_spec(Alsa.bluetooth_id("70:BF:92:04:AC:5A"))
    end

    # `amixer` takes a card and a headset is not one, so the level belongs to the
    # headset. A person turns it up on the thing on their head.
    test "has no level this firmware can set" do
      refute Alsa.volume?(Alsa.bluetooth_id("70:BF:92:04:AC:5A"))
    end
  end

  # 44100 Hz is rough on this board and 48000 Hz is clean, because USB audio needs a
  # whole number of samples in each 1 ms packet and the dwc2 controller handles the
  # alternation of 44.1 badly. The fault is in the USB controller, so it reaches USB
  # cards and no other kind.
  describe "sink_spec/1" do
    setup do
      Application.put_env(:pifi, :alsa_rate48?, true)
      on_exit(fn -> Application.delete_env(:pifi, :alsa_rate48?) end)
      :ok
    end

    # `/proc/asound/cards` says which driver holds a card, and a host that runs this
    # test holds whatever cards it holds. The name below is one that no machine has.
    test "a card that this machine does not hold takes the plug layer and not the rate" do
      assert %PiFi.Output.APlaySink{device: "plughw:CARD=Nothing,DEV=0"} =
               Alsa.sink_spec("hw:CARD=Nothing,DEV=0")
    end

    test "a name that holds no card goes through as it is" do
      assert %PiFi.Output.APlaySink{device: "default"} = Alsa.sink_spec("default")
    end

    # Naming a definition that no configuration holds gives `Unknown PCM rate48:...`
    # and no sound at all. `rootfs_overlay` holds it, so a host build must not name it.
    # `plughw:` is a device of ALSA itself, so a host holds that one.
    test "a build with no such definition still takes the plug layer" do
      Application.put_env(:pifi, :alsa_rate48?, false)

      for %{id: id} <- Alsa.devices() do
        assert %PiFi.Output.APlaySink{device: device} = Alsa.sink_spec(id)
        assert device == String.replace_prefix(id, "hw:", "plughw:")
        refute device =~ "rate48"
      end
    end

    # libmad gives `:s24le` for every MP3, which is `S24_3LE` to ALSA, and the PCM5102A
    # of a Pirate Audio offers `S16_LE`, `S24_LE` and `S32_LE` and none of those three.
    # A raw `hw:` converts nothing, so `aplay` stopped and every pipeline died with
    # `{:membrane_child_crash, :sink, :epipe}`. See `PiFi.Output.Alsa.sink_spec/1`.
    test "no card ever reaches aplay as a raw hw: device, whatever the rate setting" do
      for rate48? <- [true, false],
          id <- ["hw:CARD=Nothing,DEV=0" | Enum.map(Alsa.devices(), & &1.id)] do
        Application.put_env(:pifi, :alsa_rate48?, rate48?)

        assert %PiFi.Output.APlaySink{device: device} = Alsa.sink_spec(id)
        refute String.starts_with?(device, "hw:")
      end
    end
  end
end
