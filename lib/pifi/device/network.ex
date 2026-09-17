defmodule PiFi.Device.Network do
  @moduledoc """
  What the network is doing.

  VintageNet keeps the state of each interface. A person on the settings page
  needs the address of the device, the name of the Wi-Fi network, and the strength
  of the signal.

  The resource stores no data of its own, so it needs no data layer.
  """

  use Ash.Resource, otp_app: :pifi, domain: PiFi.Device

  actions do
    default_accept []

    action :report, {:array, :map} do
      description """
      Report each configured interface.

      A host gives an empty list, because the state comes from VintageNet, and
      that is a target dependency.
      """

      # A generic action does not cast what it returns. These fields therefore
      # describe the shape for a reader and for an API extension, and they enforce
      # nothing.
      constraints items: [
                    fields: [
                      name: [type: :string, allow_nil?: false],
                      type: [type: :string, allow_nil?: false],
                      connection: [type: :atom, allow_nil?: false],
                      addresses: [type: {:array, :string}, allow_nil?: false],
                      ssid: [type: :string, allow_nil?: true],
                      signal_percent: [type: :integer, allow_nil?: true]
                    ]
                  ]

      run PiFi.Device.Network.Report
    end
  end
end
