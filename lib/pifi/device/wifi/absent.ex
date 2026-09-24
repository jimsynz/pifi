defmodule PiFi.Device.Wifi.Absent do
  @moduledoc """
  What a device with no Wi-Fi answers.

  A host build carries no `vintage_net`, so this is what `PiFi.Device.Wifi` calls there.
  It answers rather than raising, and the settings page draws the empty state it would
  draw for a board whose adapter did not come up.
  """

  @behaviour PiFi.Device.Wifi

  @impl true
  def available?, do: false

  @impl true
  def scan, do: {:error, :no_wifi}

  @impl true
  def seen, do: []

  @impl true
  def known, do: []

  @impl true
  def join(_ssid, _passphrase), do: {:error, :no_wifi}

  @impl true
  def forget(_ssid), do: {:error, :no_wifi}
end
