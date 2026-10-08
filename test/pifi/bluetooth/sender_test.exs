defmodule PiFi.Bluetooth.SenderTest do
  use ExUnit.Case, async: true

  doctest PiFi.Bluetooth.Sender

  alias PiFi.Bluetooth.Sender

  defp pcm(path, properties) do
    %{path => %{"org.bluealsa.PCM1" => properties}}
  end

  defp telephone(extra \\ %{}) do
    Map.merge(%{"Sampling" => 44_100, "Channels" => 2}, extra)
  end

  @sending "/org/bluealsa/hci0/dev_70_BF_92_04_AC_5A/a2dpsnk/source"
  @speaker "/org/bluealsa/hci0/dev_70_BF_92_04_AC_5A/a2dpsrc/sink"

  describe "which PCMs are a telephone sending" do
    test "a telephone playing into this device is one" do
      assert [%{address: "70:BF:92:04:AC:5A"}] = Sender.parse(pcm(@sending, telephone()))
    end

    # **The two directions share the radio, the daemon and the pairing, and only the
    # path tells them apart.** A speaker this device plays to is `a2dpsrc/sink`, and
    # reading it as a sender would have the player capture its own output.
    test "a speaker this device plays to is not" do
      assert Sender.parse(pcm(@speaker, telephone())) == []
    end

    test "the ALSA name is the one arecord opens" do
      assert [%{device: "bluealsa:DEV=70:BF:92:04:AC:5A,PROFILE=a2dp"}] =
               Sender.parse(pcm(@sending, telephone()))
    end
  end

  # **A2DP negotiates the rate with the telephone**, so a guess plays the audio at the
  # wrong speed: 44100 named for a sender that agreed 48000 is 8.8% slow.
  describe "the format that the two ends agreed on" do
    test "the rate and the channel count come off the PCM" do
      assert [%{sample_rate: 48_000, channels: 1}] =
               Sender.parse(pcm(@sending, telephone(%{"Sampling" => 48_000, "Channels" => 1})))
    end

    # A stream played at a guessed rate is worse than one that does not start.
    test "a PCM that names no rate is skipped" do
      assert Sender.parse(pcm(@sending, %{"Channels" => 2})) == []
      assert Sender.parse(pcm(@sending, telephone(%{"Sampling" => 0}))) == []
    end

    test "a PCM that names no channel count is skipped" do
      assert Sender.parse(pcm(@sending, %{"Sampling" => 44_100})) == []
    end
  end

  describe "what it ignores" do
    test "an object that carries no PCM interface" do
      assert Sender.parse(%{@sending => %{"org.bluealsa.RFCOMM1" => %{}}}) == []
    end

    # bluez-alsa keeps a PCM for each direction of one device, and a telephone that
    # appeared twice would be two rows for one thing.
    test "one telephone with more than one PCM is one telephone" do
      objects =
        Map.merge(
          pcm(@sending, telephone()),
          pcm(@sending <> "/other", telephone())
        )

      assert [%{address: "70:BF:92:04:AC:5A"}] = Sender.parse(objects)
    end
  end

  describe "the window a person opens" do
    # The timeout belongs to BlueZ, so nothing here has to survive a restart to close
    # it. A window long enough to pick up a telephone and read a list.
    test "it is measured in seconds and it is not forever" do
      assert Sender.window() > 0
      assert Sender.window() <= 300
    end

    # **Bluetooth is off on a device nobody asked for it**, and off is not a crash: the
    # settings page asks these before the daemons are running.
    test "it answers rather than exiting when the bus is not there" do
      refute Sender.discoverable?()
      assert {:error, _reason} = Sender.open_window()
      assert {:error, _reason} = Sender.close_window()
    end
  end
end
