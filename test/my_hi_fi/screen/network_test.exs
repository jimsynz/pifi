defmodule MyHiFi.Screen.NetworkTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Screen.Network

  doctest MyHiFi.Screen.Network

  describe "connection/1" do
    # A device holds Wi-Fi and it may hold a cable, and one of the two carries the
    # music. The better state is therefore the state of the device.
    test "the best state of any interface is the state of the device" do
      assert Network.connection([
               %{connection: :disconnected},
               %{connection: :internet}
             ]) == :internet

      assert Network.connection([
               %{connection: :disconnected},
               %{connection: :lan}
             ]) == :lan
    end

    test "an interface that reaches nothing gives the state that it holds" do
      assert Network.connection([%{connection: :disconnected}]) == :disconnected
    end

    # A host build gives an empty list, because VintageNet is a target dependency, and
    # a screen that knows nothing must say nothing.
    test "a device that names no interface gives nothing" do
      assert Network.connection([]) == nil
    end

    # A state that this firmware does not know is not a state that it can call good.
    test "a state that this module does not name reads as disconnected" do
      assert Network.connection([%{connection: :something_else}]) == :disconnected
    end
  end

  describe "render/2" do
    # A person whose music plays needs no mark that says the network works, and 240
    # pixels hold no room for one.
    test "a network that carries the music draws nothing" do
      assert Network.render(:internet) == Network.render(nil)
      assert Network.render(:internet) == none()
    end

    # The two faults draw different colours, so the mark says which one it is without
    # a word and without a second shape. The screens measure the colours.
    test "the two faults draw different marks" do
      assert Network.render(:lan) != Network.render(:disconnected)
      refute Network.render(:lan) == none()
      refute Network.render(:disconnected) == none()
    end

    # A screen names its own size, and the mark of a larger one is not the mark of a
    # smaller one.
    test "the height is the caller's" do
      assert Network.render(:lan, height: 20) != Network.render(:lan, height: 11)
    end
  end

  # `Emerge.UI.none/0` is what an empty tree is, and this test module holds no screen to
  # bring it in.
  defp none, do: Emerge.UI.none()
end
