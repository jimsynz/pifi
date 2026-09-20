defmodule PiFi.HomeAssistantTest do
  use PiFi.DataCase, async: false

  doctest PiFi.HomeAssistant, import: true

  alias PiFi.Event
  alias PiFi.Event.Player, as: Events
  alias PiFi.HomeAssistant
  alias PiFi.HomeAssistant.Player
  alias PiFi.Settings
  alias PiFi.Test.PlayingPipeline
  alias PiFi.Test.SilentOutput
  alias PiFi.Test.Stations

  setup do
    # `PiFi.Player` is one process for the whole node, and a control of it answers
    # before it does the work. `state/0` is a call, so it waits for the work that is
    # already running. See `PiFi.Plex.CompanionTest`.
    drain = fn ->
      PiFi.Player.stop()
      PiFi.Player.state()
    end

    drain.()

    # A test that turns the bridge on leaves a listener behind, and it is registered by
    # the name of its module, so the next test that starts one meets `:already_started`.
    on_exit(fn ->
      HomeAssistant.enable(false)

      case Settings.fetch(HomeAssistant.enabled_key()) do
        {:ok, setting} -> Settings.delete!(setting)
        {:error, _reason} -> :ok
      end
    end)

    on_exit(drain)

    :ok
  end

  describe "whether a person turned it on" do
    test "a device that no person changed holds the port closed" do
      refute HomeAssistant.enabled?()
      refute HomeAssistant.running?()
    end

    test "a person turns it on, and the answer stays" do
      assert :ok = HomeAssistant.enable(true)
      assert HomeAssistant.enabled?()
    end

    test "a person turns it off again" do
      HomeAssistant.enable(true)
      assert :ok = HomeAssistant.enable(false)

      refute HomeAssistant.enabled?()
      refute HomeAssistant.running?()
    end

    # One test starts the real bridge, because the answer of a person is worth nothing
    # if the port stays shut.
    test "the control opens the port and closes it again" do
      HomeAssistant.enable(true)
      assert HomeAssistant.running?()

      HomeAssistant.enable(false)
      refute HomeAssistant.running?()
    end
  end

  # The entity runs as a process of its own, so a test starts one and speaks to it the
  # way that `Homex` does. Nothing here opens a port.
  describe "the player that Home Assistant draws" do
    setup do
      # The bridge with no adapter at all: the entity runs, and nothing is published
      # and no port is opened. See the `:adapters` option of `Homex`.
      start_supervised!({Homex, id: "test", entities: [Player]})

      # The bridge starts its entities under a dynamic supervisor, so the process of
      # this one is not there the moment that `start_supervised!` answers.
      assert eventually(fn -> is_map(Homex.Entity.snapshot(:pifi_player)) end)

      :ok
    end

    test "it reports what the device is doing when it starts" do
      assert %{state: :idle, muted: false} = snapshot()
    end

    test "a track that starts reaches the card" do
      Event.publish(:player, %Events.Started{live?: false})

      assert eventually(fn -> snapshot()[:state] == :playing end)
    end

    test "a pause and a stop reach the card" do
      Event.publish(:player, %Events.Paused{})
      assert eventually(fn -> snapshot()[:state] == :paused end)

      Event.publish(:player, %Events.Stopped{reason: :requested})
      assert eventually(fn -> snapshot()[:state] == :idle end)
    end

    # Standby is not the same as stopped: the device is asleep, and Home Assistant
    # draws a power control for it.
    test "standby draws off, and leaving it draws what the player is doing" do
      Event.publish(:player, %Events.Standby{entered?: true})
      assert eventually(fn -> snapshot()[:state] == :off end)

      Event.publish(:player, %Events.Standby{entered?: false})
      assert eventually(fn -> snapshot()[:state] == :idle end)
    end

    test "the volume of the device reaches the slider" do
      Event.publish(:player, %Events.VolumeChanged{percent: 40, enabled?: true, supported?: true})

      assert eventually(fn -> snapshot()[:volume] == 0.4 end)
    end

    test "a level of zero draws as muted" do
      Event.publish(:player, %Events.VolumeChanged{percent: 0, enabled?: true, supported?: true})

      assert eventually(fn -> snapshot()[:muted] == true end)
    end

    # A control that the player refused must not move the card, because a state that
    # the device never reached is a lie that a person reads on a dashboard.
    test "a play that the device refuses leaves the card alone" do
      Homex.Entity.send_command(:pifi_player, %{command: :play})

      assert snapshot()[:state] == :idle
    end

    test "a play of a track that is selected reaches the device" do
      PlayingPipeline.use_it()
      SilentOutput.use_it()
      station = Stations.create(%{country_code: "NZ", title: "RNZ National"})

      {:ok, :ok} = PiFi.Playback.play([station.id])
      assert eventually(fn -> snapshot()[:state] == :playing end)

      Homex.Entity.send_command(:pifi_player, %{command: :pause})

      assert eventually(fn -> snapshot()[:state] == :paused end)
      assert PiFi.Playback.state!().paused?
    end

    test "the slider of a person sets the volume of the device" do
      start_supervised!(PiFi.Output.Volume)

      Homex.Entity.send_command(:pifi_player, %{volume: 0.3})

      assert eventually(fn -> PiFi.Playback.volume!().percent == 30 end)
    end

    # ALSA holds no mute of its own, so a mute is a level of zero and the level that a
    # person had has to come back.
    test "an unmute puts the level back where a person left it" do
      start_supervised!(PiFi.Output.Volume)

      PiFi.Playback.set_volume(70)

      Homex.Entity.send_command(:pifi_player, %{command: :mute})
      assert eventually(fn -> PiFi.Playback.volume!().percent == 0 end)

      Homex.Entity.send_command(:pifi_player, %{command: :unmute})
      assert eventually(fn -> PiFi.Playback.volume!().percent == 70 end)
    end

    # Every source of this firmware resolves its own audio, and a bare address is not a
    # row of the catalogue.
    test "an address that Home Assistant sends plays nothing" do
      Homex.Entity.send_command(:pifi_player, %{media: {"http://example.test/x.mp3", false}})

      assert snapshot()[:state] == :idle
    end
  end

  defp snapshot, do: Homex.Entity.snapshot(:pifi_player) || %{}

  # The entity writes in its own process, so a test waits for it and does not sleep for
  # a period that a slow machine makes wrong.
  defp eventually(check, attempts \\ 100)

  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(20)
      eventually(check, attempts - 1)
    end
  end
end
