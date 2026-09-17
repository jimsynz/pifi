defmodule PiFi.Radio do
  @moduledoc """
  Internet radio.

  The station list comes from the public Radio Browser service.
  `PiFi.Radio.RadioBrowser` reads it, and `PiFi.Radio.Fill` writes each station
  into the catalogue of `PiFi.Playback`.

  This domain stores no station of its own. Every playable thing of this firmware is a
  `PiFi.Playback.Item`, so a user interface reads one resource and it needs no
  knowledge of any source.
  """

  use Ash.Domain, otp_app: :pifi

  resources do
    resource PiFi.Radio.Sync do
      define :sync_stations_from_remote, action: :sync_from_remote
    end
  end
end
