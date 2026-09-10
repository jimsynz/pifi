defmodule MyHiFi.Settings.Setting do
  @moduledoc """
  One configuration value.

  A device keeps its configuration here, and not in an environment variable,
  because a device has no environment to read. The settings hold the output
  device, the station countries, and the standby state.

  The value is a string. A caller that needs a list, such as the country list,
  encodes and decodes it, so this resource stays simple and the meaning stays with
  the caller.
  """

  use Ash.Resource,
    otp_app: :my_hi_fi,
    domain: MyHiFi.Settings,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "settings"
    repo MyHiFi.Repo
  end

  actions do
    default_accept []

    defaults [:read]

    read :by_key do
      description "Read one setting. It returns an error when the key is absent."

      argument :key, :string, allow_nil?: false

      get? true
      filter expr(key == ^arg(:key))
    end

    create :put do
      description """
      Write a value for a key.

      The key identifies the row, so a second call for the same key replaces the
      value.
      """

      upsert? true
      upsert_identity :key

      accept [:key, :value]
    end

    destroy :delete do
      description "Remove a setting, so the default of the caller applies again."
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      allow_nil? false
      public? true
      constraints min_length: 1
    end

    attribute :value, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  identities do
    identity :key, [:key] do
      description "One row for each key, so `put` replaces and does not duplicate."
    end
  end
end
