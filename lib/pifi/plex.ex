defmodule PiFi.Plex do
  @moduledoc """
  The music library of one Plex Media Server.

  A person runs the server themselves, and this device keeps one link to it. See
  `PiFi.Plex.Server` for the link and for the reads, and `PiFi.Source.Plex` for
  the branches that a person browses.

  This domain stores no artist, no album and no track. `PiFi.Playback.Item` keeps
  every playable thing of this firmware, and `PiFi.Plex.Fill` writes the library
  into it. What stays here is the copy of the library alone, which is the place that
  the schedule and the control of the settings page name.
  """

  use Ash.Domain, otp_app: :pifi

  resources do
    resource PiFi.Plex.Sync do
      define :sync_library, action: :sync_library
      define :cache_favourites, action: :cache_favourites
    end
  end
end
