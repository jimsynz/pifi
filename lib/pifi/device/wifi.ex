defmodule PiFi.Device.Wifi do
  @moduledoc """
  Joining and forgetting Wi-Fi networks.

  The setup wizard puts the first network on the device, and that is the only one it
  ever puts there. A person who moves the device, or changes their router, or takes it
  somewhere else has no way to tell it about the second network without writing an SD
  card. This is that way.

  ## Joining adds, it does not replace

  `join/2` appends to the list of networks the device knows, and `wpa_supplicant`
  picks whichever of them is in range. That is what lets a device that has been to two
  places reconnect at either.

  **It is also the safer order.** This page is served over the very network being
  reconfigured, so a wrong passphrase would otherwise strand the device somewhere a
  person cannot reach it. Appending leaves the working network in the list, and
  `wpa_supplicant` falls back to it when the new one does not associate.

  ## Where the implementation comes from

  `vintage_net` is a target dependency, so a host build carries no reference to it and
  `PiFi.Device.Wifi.Absent` answers instead. A test names `PiFi.Test.Wifi`. This is the
  arrangement `PiFi.Output` uses, for the same reason.
  """

  @typedoc """
  A network the adapter can see.

  `known?` says the device will join it by itself, and `security` says whether joining
  it needs a passphrase.
  """
  @type network :: %{
          ssid: String.t(),
          signal_percent: 0..100,
          security: security(),
          known?: boolean()
        }

  @typedoc """
  What a network asks for before it lets anything on.

  `:wep` is here because an adapter still reports it, not because this can join one.
  """
  @type security :: :open | :wep | :wpa2 | :wpa3 | :enterprise

  @doc "Ask the adapter to look for networks. The answers arrive a second or two later."
  @callback scan() :: :ok | {:error, term()}

  @doc "The networks the adapter saw, strongest first."
  @callback seen() :: [network()]

  @doc "The networks the device joins by itself, whether or not they are in range."
  @callback known() :: [String.t()]

  @doc "Add a network to the ones the device knows, and try it now."
  @callback join(String.t(), String.t() | nil) :: :ok | {:error, term()}

  @doc "Take a network off the list, so the device stops joining it."
  @callback forget(String.t()) :: :ok | {:error, term()}

  @doc "Whether this device has Wi-Fi at all."
  @callback available?() :: boolean()

  @doc "The module that answers for the hardware."
  @spec module() :: module()
  def module, do: Application.get_env(:pifi, :wifi, default())

  @doc "Ask the adapter to look for networks."
  @spec scan() :: :ok | {:error, term()}
  def scan, do: module().scan()

  @doc "The networks the adapter saw, strongest first."
  @spec seen() :: [network()]
  def seen, do: module().seen()

  @doc "The networks the device joins by itself."
  @spec known() :: [String.t()]
  def known, do: module().known()

  @doc """
  Add a network to the ones the device knows, and try it now.

  A passphrase of `nil` joins an open network.
  """
  @spec join(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def join(ssid, passphrase), do: module().join(ssid, passphrase)

  @doc "Take a network off the list."
  @spec forget(String.t()) :: :ok | {:error, term()}
  def forget(ssid), do: module().forget(ssid)

  @doc "Whether this device has Wi-Fi at all."
  @spec available?() :: boolean()
  def available?, do: module().available?()

  @doc """
  Whether joining this network needs a passphrase.

      iex> PiFi.Device.Wifi.needs_passphrase?(:open)
      false

      iex> PiFi.Device.Wifi.needs_passphrase?(:wpa2)
      true

  An enterprise network needs a username as well, which this cannot ask for, so it is
  not one a person can join from here.

      iex> PiFi.Device.Wifi.needs_passphrase?(:enterprise)
      false
  """
  @spec needs_passphrase?(security()) :: boolean()
  def needs_passphrase?(security), do: security in [:wpa2, :wpa3]

  @doc """
  Whether a person can join this network from this page.

      iex> PiFi.Device.Wifi.joinable?(:wpa2)
      true

  **An enterprise network is not one of them.** It authenticates a person rather than a
  device, with a username, a password and often a certificate, and the wizard this
  firmware ships cannot collect those.

      iex> PiFi.Device.Wifi.joinable?(:enterprise)
      false

  Neither is WEP. An adapter still reports it, and a router that offers it is broken in
  ways that joining would not fix.

      iex> PiFi.Device.Wifi.joinable?(:wep)
      false
  """
  @spec joinable?(security()) :: boolean()
  def joinable?(security), do: security in [:open, :wpa2, :wpa3]

  if Mix.target() == :host do
    defp default, do: PiFi.Device.Wifi.Absent
  else
    defp default, do: PiFi.Device.Wifi.Adapter
  end
end
