defmodule MyHiFi.Device.Network.Report do
  @moduledoc """
  Reads the state of each interface from VintageNet.

  `vintage_net` is a target dependency, so the host build carries no reference to
  it. A host therefore gives an empty list. See `MyHiFi.Setup` for the same
  pattern.
  """

  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _options, _context), do: {:ok, interfaces()}

  if Mix.target() == :host do
    defp interfaces, do: []
  else
    defp interfaces do
      VintageNet.configured_interfaces()
      |> Enum.sort()
      |> Enum.map(&interface/1)
    end

    defp interface(name) do
      access_point = VintageNet.get(["interface", name, "wifi", "current_ap"])

      %{
        name: name,
        type: type(VintageNet.get(["interface", name, "type"])),
        connection: VintageNet.get(["interface", name, "connection"]) || :disconnected,
        addresses: addresses(VintageNet.get(["interface", name, "addresses"])),
        ssid: access_point && access_point.ssid,
        signal_percent: access_point && access_point.signal_percent
      }
    end

    # `VintageNetWiFi` and the other technology modules name themselves, and a
    # person reads the last part.
    defp type(nil), do: "Unknown"

    defp type(module) do
      module |> Module.split() |> List.last() |> String.replace_prefix("VintageNet", "")
    end

    # A person needs the address that they can type. The IPv6 addresses of a home
    # network help no person, and the link addresses help even less.
    defp addresses(nil), do: []

    defp addresses(addresses) do
      for %{family: :inet, address: address, scope: :universe} <- addresses do
        address |> :inet.ntoa() |> to_string()
      end
    end
  end
end
