defmodule MyHiFi.Radio do
  @moduledoc """
  Internet radio.

  The station list comes from the public Radio Browser service. `MyHiFi.Radio.Station`
  holds the local copy, and each function here calls one action of that resource.
  """

  use Ash.Domain, otp_app: :my_hi_fi

  resources do
    resource MyHiFi.Radio.Station do
      define :list_stations, action: :read
      define :get_station, action: :read, get_by: [:id]
      define :search_stations, action: :search, args: [:query]
      define :favourite_stations, action: :favourites
      define :upsert_station_from_remote, action: :upsert_from_remote
      define :set_favourite, action: :set_favourite
      define :clear_favourite, action: :clear_favourite
      define :record_play, action: :record_play
    end
  end
end
