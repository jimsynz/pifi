defmodule PiFi.Device.WifiTest do
  @moduledoc """
  Which networks a person can join, and which ones this refuses.

  The joining itself belongs to VintageNet and runs on a target. What is here is the part
  that decides, and getting it wrong means offering to join a network without asking for
  the password, or asking for one that will never work.
  """

  use ExUnit.Case, async: true

  doctest PiFi.Device.Wifi

  alias PiFi.Device.Wifi
  alias PiFi.Test.Wifi, as: Double

  describe "what a person can join" do
    test "an open network needs no password" do
      refute Wifi.needs_passphrase?(:open)
      assert Wifi.joinable?(:open)
    end

    test "the two that PiFi can join with a password" do
      for security <- [:wpa2, :wpa3] do
        assert Wifi.needs_passphrase?(security)
        assert Wifi.joinable?(security)
      end
    end

    # **These two are the point of `joinable?/1`.** Both are networks an adapter reports
    # and neither is one this firmware can get onto, so the page has to say so rather
    # than draw a password box that leads nowhere.
    test "neither enterprise nor WEP is offered" do
      for security <- [:enterprise, :wep] do
        refute Wifi.joinable?(security)
        refute Wifi.needs_passphrase?(security)
      end
    end
  end

  describe "a host, which has no Wi-Fi" do
    test "reports no adapter rather than raising" do
      refute Wifi.available?()
      assert Wifi.seen() == []
      assert Wifi.known() == []
    end

    # A laptop running the test suite is the commonest case, and nothing here may take
    # the settings page down with it.
    test "answers every command with an error it can draw" do
      assert {:error, :no_wifi} = Wifi.scan()
      assert {:error, :no_wifi} = Wifi.join("Somewhere", "a password")
      assert {:error, :no_wifi} = Wifi.forget("Somewhere")
    end
  end

  describe "the double a test uses in its place" do
    test "reports what the test named" do
      Double.use_it(seen: [Double.network("Home", signal_percent: 80)], known: ["Elsewhere"])

      assert Wifi.available?()
      assert [%{ssid: "Home", signal_percent: 80}] = Wifi.seen()
      assert Wifi.known() == ["Elsewhere"]
    end

    test "marks a network the device already knows" do
      Double.use_it(seen: [Double.network("Home")], known: ["Home"])

      assert [%{ssid: "Home", known?: true}] = Wifi.seen()
    end

    test "joining adds the network to the ones it knows" do
      Double.use_it(seen: [Double.network("Home")])

      assert :ok = Wifi.join("Home", "a password")
      assert Wifi.known() == ["Home"]
      assert Double.joins() == [{"Home", "a password"}]
    end

    test "forgetting takes it off again" do
      Double.use_it(known: ["Home"])

      assert :ok = Wifi.forget("Home")
      assert Wifi.known() == []
    end

    test "forgetting one it never knew says so" do
      Double.use_it()

      assert {:error, :not_known} = Wifi.forget("Home")
    end

    test "strongest first" do
      Double.use_it(
        seen: [
          Double.network("Weak", signal_percent: 20),
          Double.network("Strong", signal_percent: 90),
          Double.network("Middling", signal_percent: 55)
        ]
      )

      assert Enum.map(Wifi.seen(), & &1.ssid) == ["Strong", "Middling", "Weak"]
    end
  end

  # **This is the logic that used to live in the adapter, where nothing could reach it.**
  # `vintage_net` is a target dependency, so a host cannot call the adapter at all — and
  # a `Map.values/1` over a list therefore reached a board and took the whole settings
  # page down with it. These are the tests that were impossible to write before.
  describe "shaping what an adapter reported" do
    defp point(ssid, options \\ []) do
      %{
        ssid: ssid,
        signal_percent: Keyword.get(options, :signal_percent, 50),
        flags: Keyword.get(options, :flags, [])
      }
    end

    # **The regression.** VintageNet puts a list in that property, not a map keyed by
    # BSSID, and the code that read it assumed a map.
    test "a list of access points is what arrives" do
      assert [%{ssid: "Home"}] = Wifi.networks([point("Home")], [])
    end

    test "nothing at all is not a failure" do
      assert Wifi.networks(nil, []) == []
      assert Wifi.networks([], []) == []
    end

    test "strongest first" do
      points = [point("Weak", signal_percent: 10), point("Strong", signal_percent: 90)]

      assert Wifi.networks(points, []) |> Enum.map(& &1.ssid) == ["Strong", "Weak"]
    end

    # One network is several access points in a house with more than one of them.
    test "several radios of one name are one network, at its best signal" do
      points = [point("Home", signal_percent: 20), point("Home", signal_percent: 75)]

      assert [%{ssid: "Home", signal_percent: 75}] = Wifi.networks(points, [])
    end

    # A hidden network reports an empty name, and there is nothing to show or join it by.
    test "a network with no name is not offered" do
      points = [point(""), point(nil), point("Home")]

      assert Wifi.networks(points, []) |> Enum.map(& &1.ssid) == ["Home"]
    end

    test "a network the device knows is marked" do
      assert [%{known?: true}] = Wifi.networks([point("Home")], ["Home"])
      assert [%{known?: false}] = Wifi.networks([point("Home")], ["Elsewhere"])
    end
  end

  describe "reading the security off an access point" do
    test "no security flags at all is an open network" do
      assert Wifi.security([:ess]) == :open
      assert Wifi.security([]) == :open
    end

    test "a pre-shared key is WPA2" do
      assert Wifi.security([:wpa2, :psk, :ccmp, :ess]) == :wpa2
    end

    # **A network offering both comes out as the stronger one.** Reading it as WPA2 would
    # join with a key exchange the access point may refuse.
    test "WPA2 and WPA3 together is WPA3" do
      assert Wifi.security([:wpa2_psk_sae_ccmp, :psk, :sae]) == :wpa3
    end

    # **An access point advertising only `FT/PSK` carries no plain `:psk`.** Reading that
    # as open would offer to join a secured network without asking for a password, which
    # is the worst of the ways this can be wrong.
    test "the fast-transition spellings are read as what they are" do
      assert Wifi.security([:ft_psk, :rsn]) == :wpa2
      assert Wifi.security([:ft_sae]) == :wpa3
      assert Wifi.security([:ft_eap]) == :enterprise
    end

    test "the sha256 spellings are read as what they are" do
      assert Wifi.security([:psk_sha256]) == :wpa2
      assert Wifi.security([:eap_sha256]) == :enterprise
    end

    # Enterprise wins over everything: a network offering both wants the username.
    test "enterprise is read ahead of the rest" do
      assert Wifi.security([:eap, :psk, :sae]) == :enterprise
    end

    test "WEP is named rather than mistaken for open" do
      assert Wifi.security([:wep]) == :wep
    end
  end
end
