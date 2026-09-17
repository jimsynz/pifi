defmodule PiFi.Jellyfin do
  @moduledoc """
  The music library of one Jellyfin server.

  A person runs the server themselves, and this device keeps one link to it. See
  `PiFi.Jellyfin.Server` for the link and for the reads, and
  `PiFi.Source.Jellyfin` for the branches that a person browses.

  This domain stores no artist, no album and no track. `PiFi.Playback.Item` keeps
  every playable thing of this firmware, and `PiFi.Jellyfin.Fill` writes the
  library into it. What stays here is the copy of the library alone, which is the
  place that the schedule and the control of the settings page name.
  """

  use Ash.Domain, otp_app: :pifi

  resources do
    resource PiFi.Jellyfin.Sync do
      define :sync_library, action: :sync_library
      define :cache_favourites, action: :cache_favourites
    end
  end
end
