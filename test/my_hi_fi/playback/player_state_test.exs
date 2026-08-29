defmodule MyHiFi.Playback.PlayerStateTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Playback

  # A pipeline that crashes holds `MyHiFi.Player` for as long as six seconds:
  # `Membrane.Pipeline.terminate/2` waits five, and the silence before it waits one.
  # Every page reads the state when it opens, and a `GenServer.call` that waits stops
  # the caller, so a crash of the pipeline took each page with it.
  describe "reading the state of a busy player" do
    test "it gives an idle state, and the caller lives" do
      instead_of_the_player(spawn(fn -> Process.sleep(:infinity) end))

      assert Playback.Player.state() == Playback.Player.idle()
    end

    test "a player that is not there gives an idle state as well" do
      instead_of_the_player(nil)

      assert %{playing?: false, item: nil} = Playback.Player.state()
    end

    # The action of the resource is what a page reads, so it must be safe as well.
    test "the action of the domain answers, and it does not raise" do
      instead_of_the_player(spawn(fn -> Process.sleep(:infinity) end))

      assert {:ok, %{playing?: false}} = Playback.state()
    end
  end

  # `MyHiFi.Player` is registered by its module name, so a test puts another process
  # under that name. `on_exit` gives the real one back however the test ends: a test
  # that stopped in the middle would otherwise leave every test after it with no
  # player.
  defp instead_of_the_player(replacement) do
    held = Process.whereis(MyHiFi.Player)
    if held, do: Process.unregister(MyHiFi.Player)
    if replacement, do: Process.register(replacement, MyHiFi.Player)

    on_exit(fn ->
      if Process.whereis(MyHiFi.Player), do: Process.unregister(MyHiFi.Player)
      if held && Process.alive?(held), do: Process.register(held, MyHiFi.Player)
    end)
  end
end
