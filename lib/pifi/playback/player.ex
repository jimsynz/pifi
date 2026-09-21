defmodule PiFi.Playback.Player do
  @moduledoc """
  The controls of the player.

  This resource stores no data, so it needs no data layer. Each action calls
  `PiFi.Player`, and that process owns the pipeline and the state.

  Read the name with care. `PiFi.Player` is the process, and this module is the
  resource in front of it.

  ## A reader of the state waits for nothing

  The player is one process, and a pipeline that crashes blocks it for as long as six
  seconds: `Membrane.Pipeline.terminate/2` waits five, and the silence before it waits
  one. A `GenServer.call` waits five seconds and then the **caller** stops.

  Every page reads the state when it opens, so a pipeline that crashed took each page
  that a person opened in that moment with it. `state/0` therefore answers `idle/0`
  when the player is busy or absent, and the next event of the player corrects the
  page. A screen that says the wrong thing for a moment is better than a screen that
  is not there.
  """

  use Ash.Resource, otp_app: :pifi, domain: PiFi.Playback

  require Logger

  alias PiFi.Output.Volume
  alias PiFi.Player.Crossfade

  # A generic action does not cast what it returns. These fields therefore describe
  # the shape for a reader and for an API extension, and they enforce nothing.
  @state_fields [
    source: [type: :atom, allow_nil?: true],
    item: [type: :map, allow_nil?: true],
    stream_title: [type: :string, allow_nil?: true],
    artwork_path: [type: :string, allow_nil?: true],
    playing?: [type: :boolean, allow_nil?: false],
    paused?: [type: :boolean, allow_nil?: false],
    standby?: [type: :boolean, allow_nil?: false],
    position_ms: [type: :integer, allow_nil?: false]
  ]

  actions do
    default_accept []

    action :state, :map do
      description """
      What the player is doing.

      **A reader of this never waits for the player and never dies with it.** See
      `idle/0`.
      """

      constraints fields: @state_fields

      run fn _input, _context -> {:ok, state()} end
    end

    action :play, :atom do
      description """
      Put a list in the queue and play one row of it.

      A person who presses a track of a list means "play this, and then the rest of the
      list", so `item_ids` is the list that they were looking at and `playing_index`
      names the row that they pressed. Next and previous then move through it. See
      `PiFi.Playback.Queue`.

      **This answers before the track plays.** A resolve reads the service of the
      source, so a fault of it arrives as `PiFi.Event.Player.Failed` and not in this
      answer. See `PiFi.Player`.
      """

      argument :item_ids, {:array, :uuid}, allow_nil?: false
      argument :playing_index, :integer, allow_nil?: false, default: 0

      run fn input, _context ->
        with {:ok, _rows} <-
               PiFi.Playback.replace_queue(input.arguments.item_ids, %{
                 playing_index: input.arguments.playing_index
               }),
             {:ok, row} <- playing_row(),
             {:ok, item} <- PiFi.Playback.get_item(row.item_id, load: [:artwork]),
             :ok <- PiFi.Player.play(item) do
          {:ok, :ok}
        else
          {:error, reason} -> {:error, reason}
        end
      end
    end

    action :stop, :atom do
      description "Stop the music."

      run fn _input, _context -> {:ok, PiFi.Player.stop()} end
    end

    action :pause, :atom do
      description """
      Stop the audio and keep the track, or start it again.

      A pause is not a stop. A stop leaves the device with nothing selected, and a
      pause leaves the track in front of the person. A play starts it at the place
      that the source reports.
      """

      argument :paused?, :boolean, allow_nil?: false

      run fn input, _context ->
        case PiFi.Player.pause(input.arguments.paused?) do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    action :next, :atom do
      description """
      Play the row after the one that plays now.

      The queue decides the order. The end of it returns `{:error, :no_more}`.
      """

      run fn _input, _context ->
        case PiFi.Player.next() do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    action :previous, :atom do
      description """
      Play the row before the one that plays now.

      A track that reached its end stays in the queue, so a person can go back to it.
      """

      run fn _input, _context ->
        case PiFi.Player.previous() do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    action :skip, :atom do
      description """
      Move inside the track that plays.

      `ms` is signed, so a backward skip is a negative number. A track that a person
      cannot move inside gives `:cannot_skip`, and a track that makes no sound yet
      gives `:not_playing`.
      """

      argument :ms, :integer, allow_nil?: false

      run fn input, _context ->
        case PiFi.Player.skip(input.arguments.ms) do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    action :standby, :atom do
      description """
      Enter standby, or leave it.

      In standby the device plays nothing and keeps the network. On leaving standby
      it plays the station that it played before.
      """

      argument :entered?, :boolean, allow_nil?: false

      run fn input, _context ->
        case PiFi.Player.standby(input.arguments.entered?) do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    action :standby_minutes, :integer do
      description """
      The minutes of quiet that the device waits for before it enters standby.

      0 means that it never enters standby by itself.
      """

      run fn _input, _context -> {:ok, PiFi.AutoStandby.minutes()} end
    end

    action :set_standby_minutes, :atom do
      description """
      Set the minutes of quiet that the device waits for before it enters standby.

      A track that plays keeps the timer off, and a control of a person starts the
      period again. 0 turns the automatic standby off. See `PiFi.AutoStandby`.
      """

      argument :minutes, :integer, allow_nil?: false

      run fn input, _context ->
        case PiFi.AutoStandby.set_minutes(input.arguments.minutes) do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    action :crossfade_seconds, :integer do
      description """
      The seconds that the end of one track plays under the start of the next.

      0 means that one track stops before the next one starts.
      """

      run fn _input, _context -> {:ok, Crossfade.seconds()} end
    end

    action :set_crossfade_seconds, :atom do
      description """
      Set the seconds that the end of one track plays under the start of the next.

      0 turns the crossfade off. It applies between two tracks of a queue, and never to
      a live stream or to a change of sample rate. A track that is already playing keeps
      the length that it started with. See `PiFi.Player.Crossfade`.
      """

      argument :seconds, :integer, allow_nil?: false

      run fn input, _context ->
        case Crossfade.set_seconds(input.arguments.seconds) do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    action :screen_blank_seconds, :integer do
      description """
      The seconds of no press that the screen of the device waits for before it goes
      dark.

      0 means that the screen stays lit.
      """

      run fn _input, _context -> {:ok, PiFi.DeviceUi.blank_seconds()} end
    end

    action :set_screen_blank_seconds, :atom do
      description """
      Set the seconds of no press that the screen of the device waits for before it
      goes dark.

      The audio continues, and only the light goes off, so this is not standby. A press
      of any button brings the screen back and does nothing else. 0 keeps the screen
      lit. See `PiFi.DeviceUi`.
      """

      argument :seconds, :integer, allow_nil?: false

      run fn input, _context ->
        case PiFi.DeviceUi.set_blank_seconds(input.arguments.seconds) do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    action :enable_source, :atom do
      description """
      Put a source in use, or take it out of use.

      The choice stays after a restart. The player stops when the source that plays
      goes out of use, so a person hears the change at once.
      """

      argument :source, :atom, allow_nil?: false
      argument :enabled?, :boolean, allow_nil?: false

      run fn input, _context ->
        case PiFi.Player.enable_source(input.arguments.source, input.arguments.enabled?) do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    action :output, :map do
      description """
      The output devices, the one that a person chose, and the one in use.

      A person who chose nothing still hears one card, so `selected` and `in_use`
      are different fields. See `PiFi.Player.output/0`.
      """

      constraints fields: [
                    devices: [type: {:array, :map}, allow_nil?: false],
                    selected: [type: :string, allow_nil?: true],
                    in_use: [type: :string, allow_nil?: true]
                  ]

      run fn _input, _context -> {:ok, PiFi.Player.output()} end
    end

    action :volume, :map do
      description """
      The level of the output, whether the control is on, and whether the card holds
      one.

      A caller reads all three together, because each one alone says nothing that a
      person can act on: a level of 30 means nothing on a card that this firmware
      cannot set. See `PiFi.Output.Volume`.
      """

      constraints fields: [
                    percent: [type: :integer, allow_nil?: false],
                    enabled?: [type: :boolean, allow_nil?: false],
                    supported?: [type: :boolean, allow_nil?: false]
                  ]

      run fn _input, _context -> {:ok, Volume.state()} end
    end

    action :set_volume, :atom do
      description """
      Set the level of the output.

      The level stays after a restart, and the hardware is told it again at each boot.
      A control that a person has not turned on takes the number and writes no card.
      """

      argument :percent, :integer, allow_nil?: false

      run fn input, _context ->
        case Volume.set_percent(input.arguments.percent) do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    action :enable_volume, :atom do
      description """
      Turn the volume control on, or off.

      Off returns the card to 0 dB, so a person never leaves a card that plays quietly
      with nothing that can raise it. See `PiFi.Output.Volume`.
      """

      argument :enabled?, :boolean, allow_nil?: false

      run fn input, _context ->
        :ok = Volume.enable(input.arguments.enabled?)

        {:ok, :ok}
      end
    end

    action :select_output, :atom do
      description """
      Choose an output device.

      The choice stays after a restart, and the player starts the stream again, so
      a person hears the change at once.
      """

      argument :id, :string, allow_nil?: false

      run fn input, _context ->
        case PiFi.Player.select_output(input.arguments.id) do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  @doc """
  What the player is doing, or `idle/0` when it cannot say.

  A pipeline that crashes blocks the player, and a caller that waited would stop with
  it. This waits one second, which is long enough for a player that is working and
  short enough that a person does not notice.
  """
  @spec state() :: map()
  def state do
    PiFi.Player.state(:timer.seconds(1))
  catch
    :exit, reason ->
      Logger.warning("The player did not say what it is doing: #{inspect(reason)}")

      idle()
  end

  @doc """
  The state of a player that plays nothing.

  A page draws this while the player is busy, and the next event of the player
  corrects it.

  **This holds every field that the player holds, and a field that it misses breaks a
  page.** `PiFiWeb.PlayerLive` reads each one by name, so a key that is absent here
  raises `KeyError` and the whole page answers 500. That happened on a board on
  2026-09-15: a resolve of a Plex track that the server converts took longer than the
  second below, this answer took its place, and the web interface stopped for a person
  who had done nothing but open it. `PiFi.Playback.PlayerTest` compares the two maps
  now.

  **`standby?` comes from the settings, and every other field is the empty one.** The
  player publishes an event for each thing that changes, so a reader that took the
  empty answer for the truth is corrected within a second: a track that plays sends
  `PiFi.Event.Player.Progress`. **Standby sends nothing while it does not change**,
  so a reader that took `false` here would hold that answer for as long as the device
  stayed in standby.

  A screen is the reader that paid for it. `PiFi.Peripheral.PirateAudio` asks this
  question when it starts, to know whether to light the panel, and the player is busy
  at that moment: it is restoring the last track from the card, which takes longer
  than the second that `state/0` waits. The screen therefore woke on a device that was
  in standby, and nothing ever put it back to sleep. A device at 192.168.3.186 on
  2026-09-11 held a lit panel for as long as it stood in standby, and its log carried
  `The player did not say what it is doing` at each boot.
  """
  @spec idle() :: map()
  def idle do
    %{
      source: nil,
      item: nil,
      stream_title: nil,
      artwork_path: nil,
      playing?: false,
      paused?: false,
      standby?: PiFi.Player.stored_standby?(),
      position_ms: 0,
      live?: false,
      crossfading?: false
    }
  end

  # An empty queue plays nothing, and `queue_playing` reads that as no row at all.
  defp playing_row do
    case PiFi.Playback.queue_playing!() do
      nil -> {:error, :nothing_to_play}
      row -> {:ok, row}
    end
  end
end
