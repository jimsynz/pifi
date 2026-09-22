defmodule PiFi.AirPlay.InfoTest do
  use ExUnit.Case, async: true

  doctest PiFi.AirPlay.Info

  alias PiFi.AirPlay.Advertisement
  alias PiFi.AirPlay.BinaryPlist
  alias PiFi.AirPlay.Info

  defp device do
    %{
      device_id: "B8:27:EB:00:11:22",
      model: "PiFi1,1",
      name: "Kitchen",
      pi: "5dccfd20-b166-49cc-a593-6abd5f724ddb",
      psi: "1f5a0b63-3e55-4d09-9b2c-8c1a6f0e2d47",
      public_key: :crypto.strong_rand_bytes(32),
      version: "1.4.0"
    }
  end

  describe "the answer to GET /info" do
    test "names this device rather than a template" do
      device = device()
      plist = Info.plist(device, "192.168.1.5:50000")

      assert plist["deviceID"] == "B8:27:EB:00:11:22"
      assert plist["name"] == "Kitchen"
      assert plist["model"] == "PiFi1,1"
      assert plist["pi"] == device.pi
      assert plist["psi"] == device.psi
      assert plist["senderAddress"] == "192.168.1.5:50000"
    end

    # A sender that finds different feature bits here and in the mDNS record behaves as
    # though the receiver were lying to it.
    test "agrees with the mDNS advertisement about what this device can do" do
      plist = Info.plist(device(), "192.168.1.5:50000")

      assert plist["features"] == Advertisement.features()
      assert plist["featuresEx"] == Advertisement.features_ex(Advertisement.features())
      assert plist["statusFlags"] == Advertisement.status_flags()
    end

    test "carries the public key as bytes and not as text" do
      device = device()

      assert Info.plist(device, "s")["pk"] == {:data, device.public_key}
    end
  end

  describe "the body that goes on the wire" do
    test "is a binary plist that reads back as the same thing" do
      device = device()

      assert {:ok, read} = BinaryPlist.decode(Info.body(device, "192.168.1.5:50000"))

      assert read["name"] == "Kitchen"
      assert read["features"] == Advertisement.features()
      assert read["senderAddress"] == "192.168.1.5:50000"
    end

    # The whole reason `pk` is tagged. A key that is not valid UTF-8 would be written as
    # a string and come back mangled, and only some keys are affected, so it would pass
    # most of the time.
    test "carries a public key back byte for byte, whatever bytes it holds" do
      for _attempt <- 1..50 do
        device = device()

        assert {:ok, read} = BinaryPlist.decode(Info.body(device, "s"))
        assert read["pk"] == device.public_key
      end
    end

    test "carries a key that is definitely not valid text" do
      device = %{device() | public_key: <<0xFF, 0xFE, 0xFD>> <> <<0::232>>}

      assert {:ok, read} = BinaryPlist.decode(Info.body(device, "s"))
      assert read["pk"] == device.public_key
    end
  end
end
