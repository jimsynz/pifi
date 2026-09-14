defmodule MyHiFi.Plex.Sync do
  @moduledoc """
  The copy of a Plex library into the catalogue.

  This resource stores no data. `MyHiFi.Playback.Item` keeps the artists, the albums
  and the tracks, and this is the place that the schedule and the control of the
  settings page name. `MyHiFi.Jellyfin.Sync` is a resource of the same shape, and
  `MyHiFi.Radio.Sync` says why each control is an action.
  """

  use Ash.Resource,
    otp_app: :my_hi_fi,
    domain: MyHiFi.Plex,
    extensions: [AshOban]

  oban do
    scheduled_actions do
      # A person adds an album to their own server, and the device shows it on the next
      # read. One read each day is often enough for a library that a household changes
      # by hand, and `MyHiFi.AutoSync` runs it when the network answers.
      #
      # The hour is not the one that Jellyfin reads at. A device that a person linked
      # to both would otherwise read two libraries at once, and one page of each is the
      # largest thing that either read keeps.
      schedule :sync_library, "0 4 * * *" do
        action :sync_library
        worker_module_name MyHiFi.Plex.Sync.Workers.Library
        queue :default
        max_attempts 3
      end

      # A mark asks for the audio at once, and a device with no network then reads
      # nothing. This asks again for each one that the card does not hold yet.
      schedule :cache_favourites, "40 * * * *" do
        action :cache_favourites
        worker_module_name MyHiFi.Plex.Sync.Workers.Favourites
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

      It returns the number of each that it wrote, and whether it read nothing at all.
      """

      run MyHiFi.Plex.Sync.Library
    end

    action :cache_favourites, :integer do
      description """
      Ask again for the audio of each marked item that the card does not hold.

      It returns the number of items that it asked for. See
      `MyHiFi.Plex.Sync.Favourites`.
      """

      run MyHiFi.Plex.Sync.Favourites
    end
  end
end
