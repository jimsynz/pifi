defmodule PiFi.AirPlay.Info do
  @moduledoc """
  What this receiver says when a sender asks `GET /info`.

  A sender asks this before it pairs and again after, and what comes back decides
  whether it offers the device at all. It repeats most of what the mDNS record already
  said, and **the two have to agree**: a sender that finds different feature bits in the
  two places behaves as though the receiver were lying, which it is.

  ## The same number three times over

  `features` is the integer, `featuresEx` is the base64 form, and the mDNS record
  carries the split-word form. All three come from `PiFi.AirPlay.Advertisement`, so
  there is one place to change and no way for them to drift apart.

  ## The public key is data and not text

  `pk` is thirty-two bytes of Ed25519 public key. It goes in as `{:data, key}`, because
  a plist has a type for bytes and `PiFi.AirPlay.BinaryPlist` will otherwise write it as
  a string — which works for most keys and fails for the ones that are not valid UTF-8.
  The mDNS record carries the same key as hex, because a TXT record has no bytes.
  """

  alias PiFi.AirPlay.Advertisement
  alias PiFi.AirPlay.BinaryPlist

  @protocol_version "1.1"
  @source_version "366.0"

  @doc """
  The answer to `GET /info`, as a map ready to encode.

  `sender` is the address the request came from, which a sender checks against what it
  thinks it dialled.
  """
  @spec plist(Advertisement.device(), String.t()) :: %{String.t() => term()}
  def plist(device, sender) do
    %{
      "deviceID" => device.device_id,
      "features" => Advertisement.features(),
      "featuresEx" => Advertisement.features_ex(Advertisement.features()),
      "initialVolume" => -24.0,
      "keepAliveLowPower" => true,
      "keepAliveSendStatsAsBody" => true,
      "manufacturer" => "PiFi",
      "model" => device.model,
      "name" => device.name,
      "pi" => device.pi,
      "pk" => {:data, device.public_key},
      "protocolVersion" => @protocol_version,
      "psi" => device.psi,
      "senderAddress" => sender,
      "sourceVersion" => @source_version,
      "statusFlags" => Advertisement.status_flags()
    }
  end

  @doc """
  The answer to `GET /info` as the bytes that go in the body.
  """
  @spec body(Advertisement.device(), String.t()) :: binary()
  def body(device, sender), do: device |> plist(sender) |> BinaryPlist.encode()
end
