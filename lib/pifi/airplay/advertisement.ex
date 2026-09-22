defmodule PiFi.AirPlay.Advertisement do
  @moduledoc """
  What this device says about itself on `_airplay._tcp`, so a telephone offers it.

  A sender decides whether to show a receiver, and what to send it, entirely from this
  advertisement. Nothing here is cosmetic: get the feature bits wrong and the device
  either does not appear in the list or appears and then fails part way through
  `SETUP`.

  ## The features number is one 64-bit value written three ways

  It says which parts of AirPlay this receiver does. The same number appears as the
  `features` key of the mDNS record, as the `fex` key beside it, and as an integer in
  the `/info` plist, and the three are written differently.

  **The mDNS form puts the low word first.** `features=0x405C4A00,0x58340` is one
  number, `0x00058340405C4A00`, split with the *less* significant half at the front.
  Writing it the other way round is a receiver a telephone will not talk to, and
  nothing about the string says which half is which.

  **`fex` is the same number little-endian, base64, with the padding taken off.**

  ## Bit 50 replaces the older metadata bits, it does not add to them

  With bit 50 set the sender sends what is playing as a binary plist to `POST /command`,
  and **nothing comes through the AirPlay 1 path at all** — not the text, the progress,
  or the artwork that bits 17, 16 and 15 ask for. Setting both sets does not get both.
  Bit 50 carries more, so it is the one this device asks for.

  ## Where these values come from

  The numbers are what Shairport Sync advertises, whose source is MIT. They are not
  guessable and there is no specification: Apple publishes none, and the meaning of each
  bit is what a working receiver was observed to claim. `0x0001C340445D0A00` is what a
  real AirPort Express sends, for comparison — it claims more than this device can do.
  """

  import Bitwise

  # Bit 2 says an audio cable is attached, which is a receiver that can play now.
  @status_flags 1 <<< 2

  # No AirPlay 2 metadata (bit 50), no AirPlay 1 text, progress or artwork (bits 17, 16,
  # 15). Those come back below.
  @base_features 0x00018340405C4A00

  # Richer metadata as a binary plist. See the moduledoc: this is instead of bits 15
  # through 17, not as well as them.
  @plist_metadata 1 <<< 50

  @features @base_features ||| @plist_metadata

  @protocol_version "1.1"
  @source_version "366.0"
  @os_version "15.0"

  @typedoc """
  What a device has to know about itself before it can say anything.

  `pi` and `psi` are UUIDs that identify this receiver and stay the same across
  restarts. `public_key` is the Ed25519 key from `PiFi.AirPlay.Identity`.
  """
  @type device :: %{
          required(:device_id) => String.t(),
          required(:model) => String.t(),
          required(:name) => String.t(),
          required(:pi) => String.t(),
          required(:psi) => String.t(),
          required(:public_key) => <<_::256>>,
          required(:version) => String.t()
        }

  @doc """
  The feature bits this device claims.

      iex> PiFi.AirPlay.Advertisement.features()
      0x00058340405C4A00
  """
  @spec features() :: non_neg_integer()
  def features, do: @features

  @doc """
  The features number as the mDNS record writes it, **low word first**.

      iex> PiFi.AirPlay.Advertisement.features_txt(0x00058340405C4A00)
      "0x405C4A00,0x58340"

  The halves are not padded, which is why the second one is five digits and not eight.

      iex> PiFi.AirPlay.Advertisement.features_txt(0x0001C340445D0A00)
      "0x445D0A00,0x1C340"
  """
  @spec features_txt(non_neg_integer()) :: String.t()
  def features_txt(features) do
    low = features &&& 0xFFFFFFFF
    high = features >>> 32

    "0x#{Integer.to_string(low, 16)},0x#{Integer.to_string(high, 16)}"
  end

  @doc """
  The features number as `fex` writes it: eight bytes little-endian, base64, no padding.

      iex> PiFi.AirPlay.Advertisement.features_ex(0)
      "AAAAAAAAAAA"
  """
  @spec features_ex(non_neg_integer()) :: String.t()
  def features_ex(features) do
    <<features::little-64>>
    |> Base.encode64()
    |> String.trim_trailing("=")
  end

  @doc """
  The TXT record for `_airplay._tcp`.

  The keys are sorted, because the order carries no meaning and a stable order is one a
  person can compare between two devices.
  """
  @spec txt_records(device()) :: [String.t()]
  def txt_records(device) do
    Enum.sort([
      "acl=0",
      "deviceid=#{device.device_id}",
      "features=#{features_txt(features())}",
      "fex=#{features_ex(features())}",
      "flags=0x#{Integer.to_string(@status_flags, 16)}",
      "fv=#{device.version}",
      "gcgl=0",
      "gid=#{device.pi}",
      "igl=0",
      "model=#{device.model}",
      "osvers=#{@os_version}",
      "pi=#{device.pi}",
      "pk=#{public_key_string(device.public_key)}",
      "protovers=#{@protocol_version}",
      "psi=#{device.psi}",
      "srcvers=#{@source_version}",
      "vv=2"
    ])
  end

  @doc """
  The service to hand `MdnsLite.add_mdns_service/1`.

  **A person turns AirPlay on**, the way they turn on Plex Companion and Spotify, so
  nothing registers this until they do. A device nobody asked advertises nothing.
  """
  @spec service(device(), 1..65_535) :: map()
  def service(device, port) do
    %{
      id: :airplay,
      instance_name: device.name,
      port: port,
      transport: "tcp",
      protocol: "airplay",
      type: "_airplay._tcp",
      txt_payload: txt_records(device)
    }
  end

  @doc """
  The Ed25519 public key the way a TXT record carries it: lower case hex, no separator.

      iex> PiFi.AirPlay.Advertisement.public_key_string(<<0xAB, 0xCD>> <> <<0::240>>)
      "abcd" <> String.duplicate("0", 60)
  """
  @spec public_key_string(binary()) :: String.t()
  def public_key_string(public_key), do: Base.encode16(public_key, case: :lower)
end
