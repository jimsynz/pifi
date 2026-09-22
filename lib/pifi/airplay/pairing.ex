defmodule PiFi.AirPlay.Pairing do
  @moduledoc """
  One telephone that a person has paired with this device.

  Pair-Setup happens once and leaves this row behind: an identifier the telephone chose
  for itself and the long-term public key it will sign with. Every connection afterwards
  is a Pair-Verify that checks a signature against this key.

  **A row here is a decision a person made.** Removing one is how they un-pair, and a
  telephone whose row is gone is a telephone that has to be paired again.

  ## Why the key is stored and not derived

  There is nothing to derive it from. The telephone generated it, sent its public half
  during pairing, and keeps the private half. This device can only remember what it was
  told, which is why losing this table means every telephone pairs again — and why
  `PiFi.AirPlay.Identity` losing its seed has the same effect in the other direction.
  """

  use Ash.Resource,
    otp_app: :pifi,
    domain: PiFi.AirPlay,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "airplay_pairings"
    repo PiFi.Repo
  end

  actions do
    default_accept []

    defaults [:read]

    read :by_identifier do
      description """
      Read one pairing. It returns an error for an identifier nobody paired, which is
      what refuses a telephone that was never set up.
      """

      argument :identifier, :string, allow_nil?: false

      get? true
      filter expr(identifier == ^arg(:identifier))
    end

    create :pair do
      description """
      Remember a telephone.

      **Pairing again replaces the key rather than adding a row.** A person who removed
      the accessory and paired again gets a new key for the same identifier, and two
      rows would leave the old key working.
      """

      upsert? true
      upsert_identity :identifier

      accept [:identifier, :public_key, :name]
    end

    destroy :forget do
      description "Un-pair a telephone, so it has to be paired again to connect."
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :identifier, :string do
      description "What the telephone calls itself. It chose this, and it is not a secret."
      allow_nil? false
      public? true
      constraints min_length: 1
    end

    attribute :public_key, :binary do
      description """
      The Ed25519 public key this telephone signs with. Thirty-two bytes, and the only
      thing that says a connection is really from it.
      """

      allow_nil? false
      public? true
    end

    attribute :name, :string do
      description "What to call it on a settings page. A telephone need not send one."
      public? true
    end

    timestamps()
  end

  identities do
    identity :identifier, [:identifier] do
      description "One row for each telephone, so pairing again replaces the key."
    end
  end
end
