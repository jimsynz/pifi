defmodule MyHiFi.Jellyfin.Sync do
  @moduledoc """
  The copy of a Jellyfin library into the catalogue.

  This resource holds no data. `MyHiFi.Playback.Item` holds the artists, the albums
  and the tracks, and this is the place that the schedule and the control of the
  settings page name. `MyHiFi.Radio.Sync` is a resource of the same shape, and it
  says why each control is an action.
  """

  use Ash.Resource,
    otp_app: :my_hi_fi,
    domain: MyHiFi.Jellyfin,
    extensions: [AshOban]

  oban do
    scheduled_actions do
      # A person adds an album to their own server, and the device shows it on the
      # next read. One read each day is often enough for a library that a household
      # changes by hand, and `MyHiFi.AutoSync` runs it when the network answers.
      schedule :sync_library, "0 3 * * *" do
        action :sync_library
        worker_module_name MyHiFi.Jellyfin.Sync.Workers.Library
        queue :default
        max_attempts 3
      end

      # A mark asks for the audio at once, and a device with no network then reads
      # nothing. This asks again for each one that the card does not hold yet.
      schedule :cache_favourites, "20 * * * *" do
        action :cache_favourites
        worker_module_name MyHiFi.Jellyfin.Sync.Workers.Favourites
        queue :default
        max_attempts 3
      end
    end
  end

  actions do
    default_accept []

    action :sync_library, :map do
      description """
      Read the artists, the albums and the tracks of the server, and write them into
      the catalogue.

      It gives the number of each that it wrote, and whether it read nothing at all.
      """

      run MyHiFi.Jellyfin.Sync.Library
    end

    action :cache_favourites, :integer do
      description """
      Ask again for the audio of each marked item that the card does not hold.

      It gives the number of items that it asked for. See
      `MyHiFi.Jellyfin.Sync.Favourites`.
      """

      run MyHiFi.Jellyfin.Sync.Favourites
    end
  end
end
