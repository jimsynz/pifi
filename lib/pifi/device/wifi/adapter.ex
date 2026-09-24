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

    ## Reading the security off an access point

    `wpa_supplicant` reports flags, and `VintageNetWiFi` parses them twice: once into the
    granular atoms below, and once into the older combined ones it keeps for
    compatibility. Both end up in the same list. Reading the granular ones is what makes
    a network that offers WPA2 and WPA3 together come out as WPA3, and it is why the
    fast-transition spellings are named here too — an access point that advertises only
    `FT/PSK` carries no plain `:psk`, and reading it as open would offer to join a
    secured network without a passphrase.
    """

    @behaviour PiFi.Device.Wifi

    alias PiFi.Device.Wifi

    @enterprise [:eap, :eap_sha256, :eap_suite_b, :eap_suite_b_192, :ft_eap]
    @wpa3 [:sae, :ft_sae]
    @wpa2 [:psk, :psk_sha256, :ft_psk]

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
          known = known()

          ["interface", interface, "wifi", "access_points"]
          |> VintageNet.get()
          |> Kernel.||(%{})
          |> Map.values()
          # A hidden network reports an empty name, and there is nothing to show or to
          # join it by.
          |> Enum.reject(&(&1.ssid in [nil, ""]))
          |> Enum.group_by(& &1.ssid)
          |> Enum.map(fn {ssid, points} -> strongest(ssid, points, known) end)
          |> Enum.sort_by(&{&1.signal_percent, &1.ssid}, :desc)
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

    # One network is several access points in a house with more than one of them, and a
    # person picks a name rather than a radio.
    defp strongest(ssid, points, known) do
      point = Enum.max_by(points, & &1.signal_percent)

      %{
        ssid: ssid,
        signal_percent: point.signal_percent,
        security: security_of(point.flags),
        known?: ssid in known
      }
    end

    defp security_of(flags) do
      cond do
        Enum.any?(@enterprise, &(&1 in flags)) -> :enterprise
        Enum.any?(@wpa3, &(&1 in flags)) -> :wpa3
        Enum.any?(@wpa2, &(&1 in flags)) -> :wpa2
        :wep in flags -> :wep
        true -> :open
      end
    end
  end
end
