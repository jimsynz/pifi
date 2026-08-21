defmodule MyHiFi.Settings do
  @moduledoc """
  The configuration of the device.

  A device has no environment to read a value from, so it keeps its configuration
  in the database. `fetch/1` reads one value, and `put/2` writes one. A caller that
  needs a default writes the `case` itself, because no caller needs one yet.
  """

  use Ash.Domain, otp_app: :my_hi_fi

  resources do
    resource MyHiFi.Settings.Setting do
      define :list_settings, action: :read
      define :fetch, action: :by_key, args: [:key]
      define :put, action: :put, args: [:key, :value]
      define :delete, action: :delete
    end
  end
end
