defmodule MyHiFi.Peripheral.NetworkWarningTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Peripheral.NetworkWarning

  doctest MyHiFi.Peripheral.NetworkWarning

  describe "connection/1" do
    # A device holds Wi-Fi and it may hold a cable, and one of the two carries the
    # music. The better state is therefore the state of the device.
    test "the best state of any interface is the state of the device" do
      assert NetworkWarning.connection([
               %{connection: :disconnected},
               %{connection: :internet}
             ]) == :internet

      assert NetworkWarning.connection([
               %{connection: :disconnected},
               %{connection: :lan}
             ]) == :lan
    end

    test "an interface that reaches nothing gives the state that it holds" do
      assert NetworkWarning.connection([%{connection: :disconnected}]) == :disconnected
    end

    # A host build gives an empty list, because VintageNet is a target dependency, and
    # a screen that knows nothing must say nothing.
    test "a device that names no interface gives nothing" do
      assert NetworkWarning.connection([]) == nil
    end

    # A state that this firmware does not know is not a state that it can call good.
    test "a state that this module does not name reads as disconnected" do
      assert NetworkWarning.connection([%{connection: :something_else}]) == :disconnected
    end
  end

  describe "text/1" do
    # A person whose music plays needs no mark that says the network works, and 240
    # pixels hold no room for one.
    test "a network that carries the music draws nothing" do
      assert NetworkWarning.text(:internet) == nil
      assert NetworkWarning.text(nil) == nil
    end

    # A device that reaches its router and nothing past it holds a Wi-Fi link that
    # works, so the words must not name Wi-Fi.
    test "a device with no way out of its network says so" do
      assert NetworkWarning.text(:lan) == "NO INTERNET"
    end

    test "a device with no network at all says that instead" do
      assert NetworkWarning.text(:disconnected) == "NO NETWORK"
    end
  end
end
