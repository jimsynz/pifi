defmodule PiFi.Bluetooth.DevicesTest do
  use ExUnit.Case, async: true

  doctest PiFi.Bluetooth.Devices

  alias PiFi.Bluetooth.Devices

  defp device(properties) do
    %{"/org/bluez/hci0/dev_x" => %{"org.bluez.Device1" => properties}}
  end

  defp speaker(extra \\ %{}) do
    Map.merge(
      %{
        "Address" => "11:22:33:44:55:66",
        "Alias" => "Kitchen Speaker",
        "UUIDs" => [Devices.audio_profile()]
      },
      extra
    )
  end

  describe "which devices are worth showing" do
    # **An adapter sees telephones, watches, keyboards and beacons.** None is a speaker,
    # and a list that offered them would ask a person to tell them apart by name.
    test "a device that cannot take audio is not in the list" do
      phone = %{
        "Address" => "aa:bb",
        "Alias" => "A phone",
        "Class" => 0x5A020C,
        "UUIDs" => ["0000111e-0000-1000-8000-00805f9b34fb"]
      }

      assert Devices.parse(device(phone)) == []
    end

    # **This is what a board actually reported**, for all five devices it found. BlueZ
    # learns the profiles by asking, and it asks when something pairs, so a filter on
    # the profiles alone hides every device a person could pair with.
    test "a speaker found by discovery has no profiles yet and is still in the list" do
      fresh = %{
        "Address" => "11:22:33:44:55:66",
        "Alias" => "Kitchen Speaker",
        "Class" => 0x240414,
        "UUIDs" => [],
        "ServicesResolved" => false
      }

      assert [%{name: "Kitchen Speaker", paired?: false}] = Devices.parse(device(fresh))
    end

    # BlueZ derives the icon from the class, and it is the friendlier half of the fact.
    test "an icon that says audio is enough" do
      by_icon = %{"Address" => "aa:bb", "Alias" => "Headphones", "Icon" => "audio-headset"}

      assert [%{name: "Headphones"}] = Devices.parse(device(by_icon))
    end

    # **A2DP is a BR/EDR profile**, so a device that advertises only over Low Energy
    # cannot carry it. That is what removes the watches and the beacons.
    test "a device with no class at all is not a candidate" do
      beacon = %{
        "Address" => "aa:bb",
        "Alias" => "aa-bb",
        "AddressType" => "random",
        "UUIDs" => []
      }

      assert Devices.parse(device(beacon)) == []
    end

    test "a speaker is" do
      assert [%{name: "Kitchen Speaker"}] = Devices.parse(device(speaker()))
    end

    # BlueZ writes these in whatever case it likes, and a filter that compared exactly
    # would drop a speaker for its spelling.
    test "the profile matches whatever case it arrives in" do
      shouted = speaker(%{"UUIDs" => [String.upcase(Devices.audio_profile())]})

      assert [%{name: "Kitchen Speaker"}] = Devices.parse(device(shouted))
    end

    test "an adapter is not a device" do
      objects = %{"/org/bluez/hci0" => %{"org.bluez.Adapter1" => %{"Powered" => true}}}

      assert Devices.parse(objects) == []
    end
  end

  describe "what a person reads" do
    # A device that answered its address and nothing else is still worth showing: the
    # address is what it is until it says more.
    test "a speaker with no name reads as its address" do
      nameless = speaker() |> Map.delete("Alias")

      assert [%{name: "11:22:33:44:55:66"}] = Devices.parse(device(nameless))
    end

    test "an empty name is no name" do
      assert [%{name: "11:22:33:44:55:66"}] = Devices.parse(device(speaker(%{"Alias" => ""})))
    end

    test "the state of a speaker comes through" do
      paired = speaker(%{"Paired" => true, "Connected" => true, "Trusted" => true})

      assert [%{paired?: true, connected?: true, trusted?: true}] = Devices.parse(device(paired))
    end

    # BlueZ leaves these out rather than saying false, and a missing property is not a
    # paired speaker.
    test "a property that BlueZ left out is false and not nil" do
      assert [%{paired?: false, connected?: false, trusted?: false}] =
               Devices.parse(device(speaker()))
    end

    test "the address is kept, because that is what bluealsa opens" do
      assert [%{address: "11:22:33:44:55:66"}] = Devices.parse(device(speaker()))
    end
  end

  # A laptop has no bus, and these must answer rather than raise.
  describe "with no bus at all" do
    test "the list says why" do
      assert {:error, _reason} = Devices.list()
    end

    test "there is no adapter" do
      assert Devices.adapter() == :error
    end

    test "discovery says there is no adapter" do
      assert {:error, :no_adapter} = Devices.discover()
    end
  end
end
