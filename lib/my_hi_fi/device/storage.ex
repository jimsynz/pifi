defmodule MyHiFi.Device.Storage do
  @moduledoc """
  How much room the device holds.

  The application data partition is the only writable storage. It mounts at
  `/root` on a target, and it holds the database, the secret, and the artwork
  later.

  The resource holds no data of its own, so it needs no data layer.
  """

  use Ash.Resource, otp_app: :my_hi_fi, domain: MyHiFi.Device

  actions do
    default_accept []

    action :report, :map do
      description """
      Report the writable partition and the size of the database.

      `used_bytes` is the space of the whole partition that is in use, and not the
      space that this firmware uses. `full?` is the alarm of `os_mon`, so it says
      that a write is near to failing and not that a threshold of this firmware
      passed.
      """

      # A generic action does not cast what it returns. These fields therefore
      # describe the shape for a reader and for an API extension, and they enforce
      # nothing.
      constraints fields: [
                    path: [type: :string, allow_nil?: false],
                    total_bytes: [type: :integer, allow_nil?: false],
                    free_bytes: [type: :integer, allow_nil?: false],
                    used_bytes: [type: :integer, allow_nil?: false],
                    database_bytes: [type: :integer, allow_nil?: false],
                    full?: [type: :boolean, allow_nil?: false]
                  ]

      run MyHiFi.Device.Storage.Report
    end
  end
end
