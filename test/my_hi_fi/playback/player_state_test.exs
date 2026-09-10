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

  # **A screen asks this question when it starts, and the player is busy at that
  # moment.** Every other field of the idle state is corrected by the next event, and
  # standby sends nothing while it does not change, so a screen that read `false` here
  # lit its panel on a device in standby and nothing put it back to sleep.
  describe "the standby state of a busy player" do
    test "it reads what the player stored, and not `false`" do
      MyHiFi.Settings.put!("standby", "true")
      on_exit(fn -> MyHiFi.Settings.put!("standby", "false") end)

      instead_of_the_player(spawn(fn -> Process.sleep(:infinity) end))

      assert %{standby?: true} = Playback.Player.state()
    end

    test "a device that is awake reads awake" do
      MyHiFi.Settings.put!("standby", "false")

      instead_of_the_player(spawn(fn -> Process.sleep(:infinity) end))

      assert %{standby?: false} = Playback.Player.state()
    end

    # A device that no person has ever put in standby holds no such setting.
    test "a device that stored nothing reads awake" do
      case MyHiFi.Settings.fetch("standby") do
        {:ok, setting} -> MyHiFi.Settings.delete!(setting)
        {:error, _reason} -> :ok
      end

      instead_of_the_player(spawn(fn -> Process.sleep(:infinity) end))

      assert %{standby?: false} = Playback.Player.state()
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
