defmodule PiFi.Repo do
  @moduledoc """
  The database of this device.

  **`config/config.exs` names the telemetry prefix, and it must.** Ecto builds that
  prefix from the name of this module, so the default here is `:pi_fi`, and every other
  event of this firmware carries `:pifi`. `AshSqlite.Repo` passes `:otp_app` and
  `:adapter` to `Ecto.Repo` and no other option, so the prefix cannot go here.
  """

  use AshSqlite.Repo, otp_app: :pifi
end
