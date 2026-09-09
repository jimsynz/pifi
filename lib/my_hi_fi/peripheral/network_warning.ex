defmodule MyHiFi.Peripheral.NetworkWarning do
  @moduledoc """
  What a screen says about the network, and when it says nothing.

  **A screen draws this only when the network cannot carry the music.** A person whose
  music is playing needs no mark that says the network works, and 240 pixels hold no
  room for one. A person whose music stopped needs to know why, and this is the
  difference between a device that is broken and a router that is off.

  It is the rule of `MyHiFi.Peripheral.BatteryIcon` and of the battery itself: a device
  on the mains draws no battery, because a battery at 0 would be a lie.

  **This gives the words, and each screen draws its own mark.** A 320 by 240 screen
  holds a row of pills and a 240 by 240 screen holds one corner, so the place, the size
  and the colour belong to the screen. See `MyHiFi.Peripheral`.

  ## The three states of VintageNet

  `connection` of an interface is `:internet`, `:lan` or `:disconnected`.

  - `:internet` needs no mark. Every source of this firmware reads a service, so this
    is the state that plays music.
  - `:lan` is a device on the network with no way out of it. A person reads that as
    working, and it plays nothing, so it is the state most worth a mark.
  - `:disconnected` is an interface with no network at all.

  **A device holds more than one interface**, and Wi-Fi and a cable both count, so the
  best state of any of them is the state of the device.
  """

  @typedoc "What VintageNet says one interface is doing."
  @type connection :: :internet | :lan | :disconnected

  # Best first. `connection/1` reads this order, so a device that holds a cable and
  # Wi-Fi takes the better of the two.
  @order [:internet, :lan, :disconnected]

  @doc """
  The state of the device, from what `MyHiFi.Device.network!/0` gives.

  It is `nil` for a device that names no interface. A host build gives an empty list,
  because VintageNet is a target dependency, and a screen that knows nothing about the
  network must say nothing about it.

      iex> MyHiFi.Peripheral.NetworkWarning.connection([%{connection: :lan}, %{connection: :internet}])
      :internet

      iex> MyHiFi.Peripheral.NetworkWarning.connection([])
      nil
  """
  @spec connection([map()]) :: connection() | nil
  def connection([]), do: nil

  def connection(interfaces) do
    states = Enum.map(interfaces, & &1.connection)

    Enum.find(@order, :disconnected, &(&1 in states))
  end

  @doc """
  The words that a screen draws, or `nil` for a network that carries the music.

  **"NO INTERNET" and not "NO WIFI".** A device that reaches its router and nothing
  past it holds a Wi-Fi link that works, and a person who read "NO WIFI" would look at
  the wrong thing.

      iex> MyHiFi.Peripheral.NetworkWarning.text(:internet)
      nil

      iex> MyHiFi.Peripheral.NetworkWarning.text(:lan)
      "NO INTERNET"

      iex> MyHiFi.Peripheral.NetworkWarning.text(:disconnected)
      "NO NETWORK"
  """
  @spec text(connection() | nil) :: String.t() | nil
  def text(:lan), do: "NO INTERNET"
  def text(:disconnected), do: "NO NETWORK"
  def text(_connection), do: nil
end
