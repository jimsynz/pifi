defmodule PiFi.AirPlay.Device do
  @moduledoc """
  The facts about this receiver that a telephone reads, gathered in one place.

  The mDNS record and `GET /info` both say who this device is, and they have to say the
  same thing. Rather than each asking around, both take this.

  ## Everything is derived from the identity key

  A receiver needs three names that stay the same across restarts: a device id, and two
  UUIDs called `pi` and `psi`. **None of them is stored**, because there is already
  something that outlives a reboot and must not change — the Ed25519 seed in
  `PiFi.AirPlay.Identity` — and deriving from it means one file to lose rather than
  four, and no way for them to disagree.

  Each is a different hash of the same public key, so knowing one says nothing about the
  others, and a device that lost its identity changes all of them together. That is the
  correct behaviour: it is a different receiver now, and every telephone should treat it
  as one.

  ## `pi` and `psi` are shaped like version 4 UUIDs and are not random

  A sender parses them as UUIDs and will reject a string that is not one, so the version
  and variant bits are set even though the bytes come from a hash. **Nothing about this
  is a claim of randomness** — they identify a device, they do not protect anything.
  """

  alias PiFi.AirPlay.Identity
  alias PiFi.Device.Identity, as: Device

  @model "PiFi1,1"

  @doc """
  Everything `PiFi.AirPlay.Advertisement` and `PiFi.AirPlay.Info` need.
  """
  @spec facts(Path.t()) :: map()
  def facts(data_dir \\ "/root") do
    key = Identity.public_key(data_dir)

    %{
      device_id: device_id(key),
      model: @model,
      name: Device.name(),
      pi: uuid(key, "pi"),
      psi: uuid(key, "psi"),
      public_key: key,
      version: version()
    }
  end

  @doc """
  The device id, which looks like a MAC address and is one only by accident of format.

  A sender expects six bytes in that shape. **The bit that says "not a real card" is
  set**, because this is a name and not an address, and a network that treated it as one
  would be wrong.

      iex> PiFi.AirPlay.Device.device_id(<<0::256>>) =~ ~r/^([0-9A-F]{2}:){5}[0-9A-F]{2}$/
      true
  """
  @spec device_id(binary()) :: String.t()
  def device_id(public_key) do
    <<first, rest::binary-size(5), _ignored::binary>> =
      :crypto.hash(:sha256, "device-id" <> public_key)

    # Bit 1 of the first byte marks an address that nobody assigned, and bit 0 clear says
    # it names one device rather than a group.
    <<Bitwise.bor(Bitwise.band(first, 0xFE), 0x02), rest::binary>>
    |> :binary.bin_to_list()
    |> Enum.map_join(":", &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
  end

  @doc """
  A UUID for this device, the same one every time.

      iex> PiFi.AirPlay.Device.uuid(<<0::256>>, "pi")
      ...> |> String.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
      true

  Two purposes give two different UUIDs from the same key.

      iex> PiFi.AirPlay.Device.uuid(<<0::256>>, "pi") == PiFi.AirPlay.Device.uuid(<<0::256>>, "psi")
      false
  """
  @spec uuid(binary(), String.t()) :: String.t()
  def uuid(public_key, purpose) do
    <<a::binary-size(6), seventh, eighth, ninth, rest::binary-size(7), _ignored::binary>> =
      :crypto.hash(:sha256, purpose <> public_key)

    version = Bitwise.bor(Bitwise.band(seventh, 0x0F), 0x40)
    variant = Bitwise.bor(Bitwise.band(ninth, 0x3F), 0x80)

    <<a::binary, version, eighth, variant, rest::binary>>
    |> Base.encode16(case: :lower)
    |> hyphenate()
  end

  @doc """
  The model this device says it is.

      iex> PiFi.AirPlay.Device.model()
      "PiFi1,1"
  """
  @spec model() :: String.t()
  def model, do: @model

  defp hyphenate(
         <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
           e::binary-size(12)>>
       ) do
    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end

  defp version do
    case :application.get_key(:pifi, :vsn) do
      {:ok, vsn} -> to_string(vsn)
      :undefined -> "0.0.0"
    end
  end
end
