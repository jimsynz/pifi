defmodule PiFi.AirPlay do
  @moduledoc """
  What this device remembers about AirPlay.

  Today that is the telephones a person has paired. The rest of AirPlay is protocol
  rather than state: `PiFi.AirPlay.PairVerify` runs the exchange, `PiFi.AirPlay.Identity`
  holds the key that outlives a reboot, and neither keeps a row.

  ## The one question the protocol asks of this

  `PiFi.AirPlay.PairVerify.finish/3` takes a function that answers "what long-term key
  belongs to this identifier". `known_key/0` is that function, and it is deliberately the
  only thing joining the protocol to what a person has set up: **a telephone nobody
  paired is an identifier this domain does not know**, and that is the whole of the
  access control.
  """

  use Ash.Domain, otp_app: :pifi

  resources do
    resource PiFi.AirPlay.Pairing do
      define :pairings, action: :read
      define :pairing_for, action: :by_identifier, args: [:identifier]
      define :pair, action: :pair, args: [:identifier, :public_key]
      define :forget_pairing, action: :forget
    end
  end

  @doc """
  The function that `PiFi.AirPlay.PairVerify.finish/3` asks.

  It answers `:error` for a telephone nobody paired, which is what refuses a connection
  from one.
  """
  @spec known_key() :: (binary() -> {:ok, binary()} | :error)
  def known_key do
    fn identifier ->
      case pairing_for(identifier) do
        {:ok, %{public_key: key}} -> {:ok, key}
        _other -> :error
      end
    end
  end
end
