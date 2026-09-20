defmodule PiFi.HomeAssistant.Player do
  @moduledoc """
  The media player that Home Assistant draws for this device.

  It is a `Homex.Entity.MediaPlayer`, so Home Assistant gets a card with a play
  control, a pause, a stop and a volume slider, and an automation can reach the same
  four things.

  ## It reads the topic, and it asks the player nothing

  **The entity is a process, and it subscribes to `:player` like any other surface of
  this firmware.** A card that read `PiFi.Playback.state/0` on a timer would ask the
  player once a second for an answer that moves when a person presses something, and
  `PiFi.Player` is one process that a pipeline can block for six seconds. The events
  carry the whole report, so this draws what it is told. See `PiFi.Event`.

  A progress event arrives once a second and changes nothing here: Home Assistant is
  not drawing a seek bar for this player, because the ESPHome media player carries no
  position. `Homex.Entity` publishes a value only when it changes, so an event that
  says the same thing costs the network nothing either way.

  ## What each control does

  | Home Assistant | This device |
  | -------------- | ----------- |
  | play           | `PiFi.Playback.pause(false)` |
  | pause          | `PiFi.Playback.pause(true)` |
  | stop           | `PiFi.Playback.stop/0` |
  | volume         | `PiFi.Playback.set_volume/1` |
  | mute           | volume 0, and the level that a person had comes back on unmute |

  **Play does not start a track that nothing selected.** `PiFi.Playback.pause(false)`
  starts the track that the device is holding, and a device holding none stays idle.
  An automation that wants music names a queue through the web interface or the device
  itself: Home Assistant has no browser for the catalogue of this device, so a
  play with nothing selected has nothing to mean.

  **Media that Home Assistant sends is refused.** `handle_media/3` is the callback for
  "play this address", and every source of this firmware resolves its own audio: a
  track is a row of the catalogue with a source, a format and a place, and a bare URL
  is none of those. A notification that a house wants spoken over the music would need
  the mixer that issue 167 is about.

  ## Standby is off, and it is not the same as stopped

  A device in standby draws `off`, and one with nothing playing draws `idle`. Home
  Assistant then shows a power control that means standby, which is what the button on
  the device means as well.
  """

  use Homex.Entity.MediaPlayer, id: :pifi_player, name: "PiFi"

  require Logger

  alias Homex.Entity.MediaPlayer
  alias PiFi.Event
  alias PiFi.Event.Player, as: Events
  alias PiFi.Playback

  @impl Homex.Entity.MediaPlayer
  def handle_init(entity) do
    Event.subscribe(:player)

    reported(entity, Playback.state!(), Playback.volume!())
  end

  @impl Homex.Entity.MediaPlayer
  def handle_info(%Events.Started{}, entity), do: MediaPlayer.set_state(entity, :playing)
  def handle_info(%Events.Buffering{}, entity), do: MediaPlayer.set_state(entity, :playing)
  def handle_info(%Events.Paused{}, entity), do: MediaPlayer.set_state(entity, :paused)
  def handle_info(%Events.Stopped{}, entity), do: MediaPlayer.set_state(entity, :idle)
  def handle_info(%Events.Failed{}, entity), do: MediaPlayer.set_state(entity, :idle)

  def handle_info(%Events.Standby{entered?: true}, entity),
    do: MediaPlayer.set_state(entity, :off)

  def handle_info(%Events.Standby{entered?: false}, entity),
    do: reported(entity, Playback.state!(), Playback.volume!())

  def handle_info(%Events.VolumeChanged{} = event, entity), do: volume(entity, event)

  def handle_info(_message, entity), do: entity

  @impl Homex.Entity.MediaPlayer
  def handle_play(entity), do: answered(entity, Playback.pause(false), :playing)

  @impl Homex.Entity.MediaPlayer
  def handle_pause(entity), do: answered(entity, Playback.pause(true), :paused)

  @impl Homex.Entity.MediaPlayer
  def handle_stop(entity), do: answered(entity, Playback.stop(), :idle)

  @impl Homex.Entity.MediaPlayer
  def handle_turn_on(entity), do: answered(entity, Playback.standby(false), :idle)

  @impl Homex.Entity.MediaPlayer
  def handle_turn_off(entity), do: answered(entity, Playback.standby(true), :off)

  @impl Homex.Entity.MediaPlayer
  def handle_volume(entity, volume) do
    _result = Playback.set_volume(round(volume * 100))

    entity
  end

  # **The level that a person had comes back**, because ALSA holds no mute of its own
  # and this firmware attenuates in software. A mute that forgot the level would leave
  # a person at zero with no way back but the slider.
  @impl Homex.Entity.MediaPlayer
  def handle_mute(entity, true) do
    entity
    |> put_private(:muted_at, Playback.volume!().percent)
    |> tap(fn _entity -> Playback.set_volume(0) end)
  end

  def handle_mute(entity, false) do
    _result = Playback.set_volume(get_private(entity, :muted_at) || 100)

    entity
  end

  @impl Homex.Entity.MediaPlayer
  def handle_media(entity, url, _announcement) do
    Logger.info("Home Assistant asked this player for #{url}, and it plays no address.")

    entity
  end

  # A control that the player refused must not move the card. The player publishes the
  # reason on its own topic, and a state that this never reached is a lie that a person
  # reads on a dashboard.
  defp answered(entity, {:ok, _result}, state), do: MediaPlayer.set_state(entity, state)

  defp answered(entity, {:error, reason}, _state) do
    Logger.warning("Home Assistant asked for something that did not happen: #{inspect(reason)}")

    entity
  end

  defp reported(entity, state, volume) do
    entity
    |> MediaPlayer.set_state(drawn(state))
    |> MediaPlayer.set_volume(volume.percent / 100)
    |> MediaPlayer.set_muted(volume.percent == 0)
  end

  defp volume(entity, %Events.VolumeChanged{percent: percent}) do
    entity
    |> MediaPlayer.set_volume(percent / 100)
    |> MediaPlayer.set_muted(percent == 0)
  end

  defp drawn(%{standby?: true}), do: :off
  defp drawn(%{playing?: true}), do: :playing
  defp drawn(%{paused?: true, item: item}) when not is_nil(item), do: :paused
  defp drawn(_state), do: :idle
end
