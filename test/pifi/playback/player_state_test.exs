defmodule PiFi.Playback.PlayerStateTest do
  use PiFi.DataCase, async: false

  alias PiFi.Playback

  # **A reader of the player must never wait for it and never die with it.** The work of
  # a play runs in a continue — a resolve that reads a service, an old pipeline that
  # `Membrane.Pipeline.terminate/2` waits five seconds for — so a `GenServer.call` that
  # queued behind it stopped every page that opened in that window.
  #
  # `PiFi.Player.status/0` reads the table that the player writes as each callback
  # returns, so there is no call to queue. These tests are about the answer when there
  # is no table to read: a player that is not running yet, or one that has gone.
  describe "reading the state with no player" do
    test "it gives an idle state, and the caller lives" do
      without_the_player(fn ->
        assert Playback.Player.state() == Playback.Player.idle()
      end)
    end

    # The action of the resource is what a page reads, so it must be safe as well.
    test "the action of the domain answers, and it does not raise" do
      without_the_player(fn ->
        assert {:ok, %{playing?: false}} = Playback.state()
      end)
    end

    # **A field that this answer misses breaks a page.** `PiFiWeb.PlayerLive` reads
    # each one by name, so a key that is absent raises `KeyError` and the whole page
    # answers 500. A board on 2026-09-15 did that: a resolve of a Plex track that the
    # server converts took longer than the second that the read waited, this answer
    # took the place of the real one, and it held no `live?`.
    test "it holds every field that the player holds" do
      real = PiFi.Player.state()

      assert Map.keys(Playback.Player.idle()) |> Enum.sort() == Map.keys(real) |> Enum.sort()
    end
  end

  # **A screen asks this question when it starts, and the player is restoring the last
  # track at that moment.** Every other field is corrected by the next event, and
  # standby sends nothing while it does not change, so a screen that read `false` here
  # lit its panel on a device in standby and nothing put it back to sleep. A board at
  # 192.168.3.186 held a lit panel on 2026-09-11 for as long as it stood in standby.
  #
  # `PiFi.Player.init/1` therefore makes its table and writes nothing to it: `%State{}`
  # says `standby?: false` and the stored answer arrives in the continue after it, so
  # there must be no state to read until that has run.
  describe "the standby state with no player" do
    test "it reads what the player stored, and not `false`" do
      PiFi.Settings.put!("standby", "true")

      without_the_player(fn ->
        assert %{standby?: true} = Playback.Player.state()
      end)
    end

    test "a device that is awake reads awake" do
      PiFi.Settings.put!("standby", "false")

      without_the_player(fn ->
        assert %{standby?: false} = Playback.Player.state()
      end)
    end

    # A device that no person has ever put in standby holds no such setting.
    test "a device that stored nothing reads awake" do
      case PiFi.Settings.fetch("standby") do
        {:ok, setting} -> PiFi.Settings.delete!(setting)
        {:error, _reason} -> :ok
      end

      without_the_player(fn ->
        assert %{standby?: false} = Playback.Player.state()
      end)
    end
  end

  # **The table goes when the player goes**, so taking the child away is the one way to
  # read the answer for a device that has no state yet. The supervisor puts it back
  # however the test ends: a test that stopped in the middle would otherwise leave
  # every test after it with no player.
  #
  # **The player that comes back reads the stored standby, and these tests write it.**
  # One left asleep draws every page after it as a device in standby, which is 108
  # tests of the web interface failing for a setting that this file wrote.
  defp without_the_player(check) do
    :ok = Supervisor.terminate_child(PiFi.Supervisor, PiFi.Player)

    try do
      check.()
    after
      {:ok, _pid} = Supervisor.restart_child(PiFi.Supervisor, PiFi.Player)

      PiFi.Player.standby(false)
    end
  end
end
