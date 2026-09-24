if Mix.target() != :host do
  defmodule PiFi.Device.Wifi.Adapter do
    @moduledoc """
    Wi-Fi through VintageNet.

    `vintage_net` is a target dependency, so this module exists on a target and nowhere
    else. `PiFi.Device.Wifi.Absent` is what a host gets. See `PiFi.Setup` for the same
    shape.

    ## The interface is found rather than named

    `config/target.exs` calls it `wlan0` today, and a board with a second adapter, or a
    system that enumerates differently, would not. The Wi-Fi interface is the configured
    one whose technology is `VintageNetWiFi`, which stays true either way.

    ## A scan takes a moment, and one scan is not enough

    `VintageNet.scan/1` asks the adapter to look and returns straight away. The results
    land in the property table a second or two later, and an adapter reports a different
    subset of the neighbourhood on each sweep. `seen/0` therefore reads whatever has
    accumulated rather than the result of one sweep, and the settings page asks again
    every few seconds while a person is choosing.

    ## Nothing here decides anything

    **This module cannot be tested.** `vintage_net` is a target dependency, so it does
    not exist on a host and nothing on a host can call it — which is how a `Map.values/1`
    over a list reached a board and took the whole settings page down with it. Every
    judgement, including reading the security off an access point, is in
    `PiFi.Device.Wifi` where a test can reach it. What is left here is calls into
    VintageNet.
    """

    @behaviour PiFi.Device.Wifi

    alias PiFi.Device.Wifi

    # wpa_supplicant refuses anything shorter, so it is worth saying so here rather than
    # persisting a configuration that will never associate.
    @shortest_passphrase 8

    @impl true
    def available?, do: interface() != nil

    @impl true
    def scan do
      with {:ok, interface} <- wifi_interface() do
        case VintageNet.scan(interface) do
          :ok -> :ok
          {:ok, _anything} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    end

    @impl true
    def seen do
      case wifi_interface() do
        {:error, _reason} ->
          []

        {:ok, interface} ->
          ["interface", interface, "wifi", "access_points"]
          |> VintageNet.get()
          |> Wifi.networks(known())
      end
    end

    @impl true
    def known do
      case wifi_interface() do
        {:error, _reason} -> []
        {:ok, interface} -> interface |> networks() |> Enum.map(& &1.ssid)
      end
    end

    @impl true
    def join(ssid, passphrase) do
      with {:ok, interface} <- wifi_interface(),
           {:ok, network} <- network_for(ssid, passphrase) do
        # Everything else about the interface stays as it was, addressing included. Only
        # the list of networks changes, and the one being joined replaces any earlier
        # entry of the same name rather than sitting beside it.
        others = Enum.reject(networks(interface), &(&1.ssid == ssid))

        write(interface, others ++ [network])
      end
    end

    @impl true
    def forget(ssid) do
      with {:ok, interface} <- wifi_interface() do
        configured = networks(interface)

        case Enum.reject(configured, &(&1.ssid == ssid)) do
          ^configured -> {:error, :not_known}
          remaining -> write(interface, remaining)
        end
      end
    end

    defp interface do
      Enum.find(VintageNet.configured_interfaces(), fn name ->
        VintageNet.get(["interface", name, "type"]) == VintageNetWiFi
      end)
    end

    defp wifi_interface do
      case interface() do
        nil -> {:error, :no_wifi}
        name -> {:ok, name}
      end
    end

    defp networks(interface) do
      interface
      |> configuration()
      |> Map.get(:vintage_net_wifi, %{})
      |> Map.get(:networks, [])
      |> List.wrap()
    end

    defp write(interface, networks) do
      configuration =
        interface
        |> configuration()
        |> Map.update(:vintage_net_wifi, %{networks: networks}, fn wifi ->
          Map.put(wifi, :networks, networks)
        end)

      VintageNet.configure(interface, configuration, persist: true)
    end

    # `get_configuration/1` raises for an interface it has no configuration for, which is
    # a race against an adapter going away rather than a state worth crashing on.
    defp configuration(interface) do
      VintageNet.get_configuration(interface)
    rescue
      RuntimeError -> %{}
    end

    defp network_for(ssid, passphrase) do
      security = security(ssid)

      cond do
        security == :open ->
          {:ok, %{ssid: ssid, key_mgmt: :none}}

        not Wifi.joinable?(security) ->
          {:error, {:unsupported_security, security}}

        not is_binary(passphrase) or byte_size(passphrase) < @shortest_passphrase ->
          {:error, :passphrase_too_short}

        security == :wpa3 ->
          {:ok, %{ssid: ssid, key_mgmt: :sae, sae_password: passphrase}}

        true ->
          {:ok, %{ssid: ssid, key_mgmt: :wpa_psk, psk: passphrase}}
      end
    end

    # A network a person typed the name of themselves is in no scan, and there is nothing
    # left to go on. WPA2 is the assumption that joins the most home routers.
    defp security(ssid) do
      case Enum.find(seen(), &(&1.ssid == ssid)) do
        nil -> :wpa2
        network -> network.security
      end
    end
  end
end
