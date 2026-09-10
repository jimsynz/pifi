defmodule MyHiFi.Radio do
  @moduledoc """
  Internet radio.

  The station list comes from the public Radio Browser service.
  `MyHiFi.Radio.RadioBrowser` reads it, and `MyHiFi.Radio.Fill` writes each station
  into the catalogue of `MyHiFi.Playback`.

  This domain stores no station of its own. Every playable thing of this firmware is a
  `MyHiFi.Playback.Item`, so a user interface reads one resource and it needs no
  knowledge of any source.
  """

  use Ash.Domain, otp_app: :my_hi_fi

  resources do
    resource MyHiFi.Radio.Sync do
      define :sync_stations_from_remote, action: :sync_from_remote
    end
  end
end
