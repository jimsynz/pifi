defmodule PiFi.Source.BluetoothTest do
  use PiFi.DataCase, async: false

  doctest PiFi.Source.Bluetooth

  alias PiFi.Settings
  alias PiFi.Source

  setup do
    on_exit(fn ->
      case Settings.fetch(Source.enabled_key(Source.Bluetooth)) do
        {:ok, setting} -> Settings.delete!(setting)
        {:error, _reason} -> :ok
      end
    end)

    :ok
  end

  # **A telephone is shaped like a radio station**: the item is the input and the song
  # playing arrives beside it. One row, not one for each track — an SD card has a finite
  # number of writes and a track a telephone sent is in no catalogue.
  describe "the item that stands for the input" do
    test "there is one, and asking twice gives the same one" do
      first = Source.Bluetooth.item()
      second = Source.Bluetooth.item()

      assert first.id == second.id
      assert first.source == "bluetooth"
    end

    test "it is live, because a telephone decides when it ends" do
      assert %{live?: true, kind: :track} = Source.Bluetooth.item()
    end
  end

  describe "what it cannot do" do
    test "it has no branches" do
      assert {:error, Source.Bluetooth} = Source.Bluetooth.roots()
    end

    test "it offers no controls, because the telephone holds them" do
      assert Source.Bluetooth.capabilities() == []
      assert Source.Bluetooth.kinds() == []
    end
  end

  # **The ALSA name is not in the playable.** A2DP negotiates the rate with the
  # telephone and the pipeline is built again whenever the output changes, so both are
  # read when the pipeline is built. See `PiFi.Player.Pipeline`.
  describe "what it resolves to" do
    test "it names the transport and leaves the device to the pipeline" do
      assert {:ok, playable} = Source.Bluetooth.resolve(Source.Bluetooth.item())

      assert playable.transport == :bluetooth
      assert playable.format == :raw
      assert playable.container == :none
    end

    test "it is live, so nothing counts against a length and nothing seeks" do
      assert {:ok, %{live?: true, position_ms: 0, position_bytes: nil}} =
               Source.Bluetooth.resolve(Source.Bluetooth.item())
    end
  end

  # **A radio that answers anything in range is not what a device nobody asked for
  # should be running**, so this is off until a person says otherwise.
  describe "whether a person has asked for it" do
    test "a device that no person changed leaves it off" do
      refute Source.Bluetooth.ready?()
      refute Source.enabled?(Source.Bluetooth)
    end

    test "a person who turns it on wins over that" do
      Source.enable(Source.Bluetooth, true)

      assert Source.enabled?(Source.Bluetooth)
    end
  end

  test "it is one of the sources a user interface draws" do
    assert Source.Bluetooth in Source.all()
  end
end
