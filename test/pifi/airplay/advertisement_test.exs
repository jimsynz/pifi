defmodule PiFi.AirPlay.AdvertisementTest do
  use ExUnit.Case, async: true

  import Bitwise

  doctest PiFi.AirPlay.Advertisement

  alias PiFi.AirPlay.Advertisement

  defp device do
    %{
      device_id: "B8:27:EB:00:11:22",
      model: "PiFi1,1",
      name: "Kitchen",
      pi: "5dccfd20-b166-49cc-a593-6abd5f724ddb",
      psi: "1f5a0b63-3e55-4d09-9b2c-8c1a6f0e2d47",
      public_key: <<0xAB, 0xCD>> <> <<0::240>>,
      version: "1.4.0"
    }
  end

  defp txt(records, key) do
    Enum.find_value(records, fn record ->
      case String.split(record, "=", parts: 2) do
        [^key, value] -> value
        _other -> nil
      end
    end)
  end

  describe "the features number" do
    test "sets bit 50, so metadata arrives as a plist" do
      assert (Advertisement.features() &&& 1 <<< 50) != 0
    end

    # The moduledoc says bit 50 is instead of these and not as well as them. If someone
    # sets one of them later, metadata stops arriving and nothing says why.
    test "leaves the AirPlay 1 text, progress and artwork bits clear" do
      for bit <- [15, 16, 17] do
        assert (Advertisement.features() &&& 1 <<< bit) == 0, "bit #{bit} is set"
      end
    end

    test "is the value a working receiver advertises" do
      assert Advertisement.features() == 0x00058340405C4A00
    end
  end

  describe "writing the features number for mDNS" do
    # Taken from the comment in the reference, which states the ordering in words and
    # then gives this pair. It is the only independent statement of which half is which.
    test "puts the low word first, as the reference documents" do
      assert Advertisement.features_txt(0x1C340405F4A00) == "0x405F4A00,0x1C340"
    end

    test "survives a round trip through the two halves" do
      for value <- [0, 1, 0x00058340405C4A00, 0x0001C340445D0A00, 0xFFFFFFFFFFFFFFFF] do
        ["0x" <> low, "0x" <> high] = String.split(Advertisement.features_txt(value), ",")

        rebuilt = String.to_integer(low, 16) ||| String.to_integer(high, 16) <<< 32

        assert rebuilt == value
      end
    end

    test "writes each half in upper case" do
      text = Advertisement.features_txt(0x00058340405C4A00)

      assert text == String.upcase(text, :ascii) |> String.replace("0X", "0x")
    end

    test "a number that fits in the low word alone says so" do
      assert Advertisement.features_txt(0xFF) == "0xFF,0x0"
    end
  end

  describe "writing the features number for fex" do
    test "is the same number little-endian, base64, with the padding gone" do
      value = 0x00058340405C4A00

      assert encoded = Advertisement.features_ex(value)
      refute String.contains?(encoded, "=")
      assert {:ok, <<decoded::little-64>>} = Base.decode64(encoded, padding: false)
      assert decoded == value
    end

    test "round trips every byte position" do
      for shift <- 0..7 do
        value = 0xA5 <<< (shift * 8)

        assert {:ok, <<decoded::little-64>>} =
                 Base.decode64(Advertisement.features_ex(value), padding: false)

        assert decoded == value
      end
    end

    test "is eleven characters, which is eight bytes without the padding" do
      assert String.length(Advertisement.features_ex(0x00058340405C4A00)) == 11
    end
  end

  describe "the TXT record" do
    test "carries every key a sender looks for" do
      records = Advertisement.txt_records(device())

      for key <- ~w[acl deviceid features fex flags fv gcgl gid igl model
                    osvers pi pk protovers psi srcvers vv] do
        assert txt(records, key), "no #{key} in the record"
      end
    end

    test "names this device rather than a template" do
      records = Advertisement.txt_records(device())

      assert txt(records, "deviceid") == "B8:27:EB:00:11:22"
      assert txt(records, "model") == "PiFi1,1"
      assert txt(records, "fv") == "1.4.0"
      assert txt(records, "pi") == "5dccfd20-b166-49cc-a593-6abd5f724ddb"
      assert txt(records, "psi") == "1f5a0b63-3e55-4d09-9b2c-8c1a6f0e2d47"
    end

    test "carries the public key as sixty-four lower case hex digits" do
      key = :crypto.strong_rand_bytes(32)
      records = Advertisement.txt_records(%{device() | public_key: key})

      assert written = txt(records, "pk")
      assert String.length(written) == 64
      assert written == String.downcase(written)
      assert Base.decode16!(written, case: :lower) == key
    end

    test "says it is alone rather than leading a group" do
      records = Advertisement.txt_records(device())

      assert txt(records, "gcgl") == "0"
      assert txt(records, "igl") == "0"
      assert txt(records, "gid") == txt(records, "pi")
    end

    test "agrees with the features functions" do
      records = Advertisement.txt_records(device())

      assert txt(records, "features") == Advertisement.features_txt(Advertisement.features())
      assert txt(records, "fex") == Advertisement.features_ex(Advertisement.features())
    end

    test "is sorted, so two devices can be compared line by line" do
      records = Advertisement.txt_records(device())

      assert records == Enum.sort(records)
    end

    test "names each key once" do
      keys =
        Advertisement.txt_records(device())
        |> Enum.map(&(String.split(&1, "=", parts: 2) |> hd()))

      assert keys == Enum.uniq(keys)
    end
  end

  describe "the service handed to mdns_lite" do
    test "advertises on the type a sender browses for" do
      service = Advertisement.service(device(), 7000)

      assert service.type == "_airplay._tcp"
      assert service.transport == "tcp"
      assert service.port == 7000
    end

    test "carries the name a person gave the device, and its records" do
      service = Advertisement.service(device(), 7000)

      assert service.instance_name == "Kitchen"
      assert service.txt_payload == Advertisement.txt_records(device())
    end

    test "names itself, so turning AirPlay off can remove it" do
      assert Advertisement.service(device(), 7000).id == :airplay
    end
  end
end
