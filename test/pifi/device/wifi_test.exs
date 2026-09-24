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
end
