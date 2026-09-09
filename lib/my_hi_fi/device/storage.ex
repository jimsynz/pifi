defmodule MyHiFi.Device.Storage do
  @moduledoc """
  How much room the device holds.

  The application data partition is the only writable storage. It mounts at
  `/root` on a target, and it holds the database, the secret, and the artwork
  later.

  The resource holds no data of its own, so it needs no data layer.

  `report` gives the numbers of the whole partition, and `usage` says which kind of
  media holds the room. The two are separate actions because `report` runs at each
  settle of `MyHiFi.Device.Monitor` and `usage` reads the cache and the items, which
  is work that only the storage page needs.
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

    action :usage, {:array, :map} do
      description """
      Report what uses the room of the partition, one kind of media at a time.

      A person who reads "3.6 GB used" learns nothing that they can act on. This
      names the kinds, so they know whether to remove the downloads of one source or
      to clear the artwork.

      The kinds sum to `used_bytes` of `report`, because `other` holds the rest: the
      firmware, the logs and what a file system needs for 10000 small files. The
      largest kind comes first, and a kind that holds no byte is absent.
      """

      constraints items: [
                    fields: [
                      key: [type: :string, allow_nil?: false],
                      label: [type: :string, allow_nil?: false],
                      bytes: [type: :integer, allow_nil?: false]
                    ]
                  ]

      run MyHiFi.Device.Storage.Usage
    end
  end
end
