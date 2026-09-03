defmodule MyHiFi.Jellyfin do
  @moduledoc """
  The music library of one Jellyfin server.

  A person runs the server themselves, and this device holds one link to it. See
  `MyHiFi.Jellyfin.Server` for the link and for the reads, and
  `MyHiFi.Source.Jellyfin` for the branches that a person browses.

  This domain holds no artist, no album and no track. `MyHiFi.Playback.Item` holds
  every playable thing of this firmware, and `MyHiFi.Jellyfin.Fill` writes the
  library into it. What stays here is the copy of the library alone, which is the
  place that the schedule and the control of the settings page name.
  """

  use Ash.Domain, otp_app: :my_hi_fi

  resources do
    resource MyHiFi.Jellyfin.Sync do
      define :sync_library, action: :sync_library
      define :cache_favourites, action: :cache_favourites
    end
  end
end
