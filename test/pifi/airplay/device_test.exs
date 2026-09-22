defmodule PiFi.AirPlay.DeviceTest do
  use ExUnit.Case, async: true

  doctest PiFi.AirPlay.Device

  alias PiFi.AirPlay.Device

  defp key, do: :crypto.strong_rand_bytes(32)

  describe "the device id" do
    test "is shaped the way a sender expects" do
      assert Device.device_id(key()) =~ ~r/^([0-9A-F]{2}:){5}[0-9A-F]{2}$/
    end

    # It is a name and not an address. A network that treated it as a real card's would
    # be wrong, and the bit that says so is what stops that.
    test "says it was not assigned by anybody" do
      for _attempt <- 1..50 do
        <<first::binary-size(2), _rest::binary>> = Device.device_id(key())
        byte = String.to_integer(first, 16)

        assert Bitwise.band(byte, 0x02) == 0x02, "not marked as locally administered"
        assert Bitwise.band(byte, 0x01) == 0x00, "marked as a group address"
      end
    end

    test "is the same every time for the same key" do
      key = key()

      assert Device.device_id(key) == Device.device_id(key)
    end

    test "is different for a different key" do
      ids = for _attempt <- 1..50, do: Device.device_id(key())

      assert length(Enum.uniq(ids)) == 50
    end
  end

  describe "the UUIDs" do
    test "are shaped like version 4" do
      for purpose <- ["pi", "psi"] do
        assert Device.uuid(key(), purpose) =~
                 ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      end
    end

    test "are the same every time for the same key" do
      key = key()

      assert Device.uuid(key, "pi") == Device.uuid(key, "pi")
    end

    # Knowing one must say nothing about the other, which is why each is a hash of the
    # key with its own purpose rather than slices of one hash.
    test "differ from each other and across keys" do
      pairs = for _attempt <- 1..50, do: {key(), nil}

      pis = Enum.map(pairs, fn {key, _} -> Device.uuid(key, "pi") end)
      psis = Enum.map(pairs, fn {key, _} -> Device.uuid(key, "psi") end)

      assert length(Enum.uniq(pis)) == 50
      assert length(Enum.uniq(psis)) == 50
      assert Enum.all?(Enum.zip(pis, psis), fn {one, other} -> one != other end)
    end

    # A device that lost its identity is a different receiver, and every telephone
    # should treat it as one. All three names moving together is what makes that true.
    test "change together when the key changes" do
      one = key()
      other = key()

      assert Device.device_id(one) != Device.device_id(other)
      assert Device.uuid(one, "pi") != Device.uuid(other, "pi")
      assert Device.uuid(one, "psi") != Device.uuid(other, "psi")
    end
  end

  describe "the facts" do
    setup do
      dir = Path.join(System.tmp_dir!(), "airplay-device-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)

      %{dir: dir}
    end

    test "carry everything the advertisement and /info need", %{dir: dir} do
      facts = Device.facts(dir)

      for field <- [:device_id, :model, :name, :pi, :psi, :public_key, :version] do
        assert Map.has_key?(facts, field), "no #{field}"
        assert Map.fetch!(facts, field)
      end

      assert byte_size(facts.public_key) == 32
      assert facts.model == "PiFi1,1"
    end

    test "are the same across two reads, because the key outlives them", %{dir: dir} do
      assert Device.facts(dir) == Device.facts(dir)
    end

    test "are derived from the identity and not stored beside it", %{dir: dir} do
      Device.facts(dir)

      assert File.ls!(dir) == ["airplay_identity"]
    end
  end
end
