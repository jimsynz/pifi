defmodule PiFi.Device do
  @moduledoc """
  What the machine under the firmware is doing.

  The network state and the storage state are reports. A caller reads them, and
  no caller changes them here. The Wi-Fi details belong to the setup wizard, and
  the free space belongs to the partition.

  Each report is a generic action and not a plain function, so an API extension
  such as `ash_json_api` can serve it, and a policy can guard it later. See the
  Ash guide on generic actions.
  """

  use Ash.Domain, otp_app: :pifi

  resources do
    resource PiFi.Device.Network do
      define :network, action: :report
    end

    resource PiFi.Device.Storage do
      define :storage, action: :report
      define :storage_usage, action: :usage
    end
  end
end
