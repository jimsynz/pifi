defmodule MyHiFi.Playback.Player do
  @moduledoc """
  The controls of the player.

  This resource holds no data, so it needs no data layer. Each action calls
  `MyHiFi.Player`, and that process holds the pipeline and the state.

  Read the name with care. `MyHiFi.Player` is the process, and this module is the
  resource in front of it.

  ## A reader of the state waits for nothing

  The player is one process, and a pipeline that crashes holds it for as long as six
  seconds: `Membrane.Pipeline.terminate/2` waits five, and the silence before it waits
  one. A `GenServer.call` waits five seconds and then the **caller** stops.

  Every page reads the state when it opens, so a pipeline that crashed took each page
  that a person opened in that moment with it. `state/0` therefore answers `idle/0`
  when the player is busy or absent, and the next event of the player corrects the
  page. A screen that says the wrong thing for a moment is better than a screen that
  is not there.
  """

  use Ash.Resource, otp_app: :my_hi_fi, domain: MyHiFi.Playback

  require Logger

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
      `MyHiFi.Playback.Queue`.
      """

      argument :item_ids, {:array, :uuid}, allow_nil?: false
      argument :playing_index, :integer, allow_nil?: false, default: 0

      run fn input, _context ->
        with {:ok, _rows} <-
               MyHiFi.Playback.replace_queue(input.arguments.item_ids, %{
                 playing_index: input.arguments.playing_index
               }),
             {:ok, row} <- playing_row(),
             {:ok, item} <- MyHiFi.Playback.get_item(row.item_id, load: [:artwork]),
             :ok <- MyHiFi.Player.play(item) do
          {:ok, :ok}
        else
          {:error, reason} -> {:error, reason}
        end
      end
    end

    action :stop, :atom do
      description "Stop the music."

      run fn _input, _context -> {:ok, MyHiFi.Player.stop()} end
    end

    action :pause, :atom do
      description """
      Stop the audio and keep the track, or start it again.

      A pause is not a stop. A stop leaves the device with nothing selected, and a
      pause leaves the track in front of the person. A play starts it at the place
      that the source holds.
      """

      argument :paused?, :boolean, allow_nil?: false

      run fn input, _context ->
        case MyHiFi.Player.pause(input.arguments.paused?) do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    action :next, :atom do
      description """
      Play the row after the one that plays now.

      The queue holds the order. The end of it gives `{:error, :no_more}`.
      """

      run fn _input, _context ->
        case MyHiFi.Player.next() do
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
        case MyHiFi.Player.previous() do
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
        case MyHiFi.Player.skip(input.arguments.ms) do
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
        case MyHiFi.Player.standby(input.arguments.entered?) do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    action :standby_minutes, :integer do
      description """
      The minutes of quiet that the device waits for before it enters standby.

      0 means that it enters standby by itself never.
      """

      run fn _input, _context -> {:ok, MyHiFi.AutoStandby.minutes()} end
    end

    action :set_standby_minutes, :atom do
      description """
      Set the minutes of quiet that the device waits for before it enters standby.

      A track that plays holds the timer off, and a control of a person starts the
      period again. 0 turns the automatic standby off. See `MyHiFi.AutoStandby`.
      """

      argument :minutes, :integer, allow_nil?: false

      run fn input, _context ->
        case MyHiFi.AutoStandby.set_minutes(input.arguments.minutes) do
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
        case MyHiFi.Player.enable_source(input.arguments.source, input.arguments.enabled?) do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    action :output, :map do
      description """
      The output devices, the one that a person chose, and the one in use.

      A person who chose nothing still hears one card, so `selected` and `in_use`
      are different fields. See `MyHiFi.Player.output/0`.
      """

      constraints fields: [
                    devices: [type: {:array, :map}, allow_nil?: false],
                    selected: [type: :string, allow_nil?: true],
                    in_use: [type: :string, allow_nil?: true]
                  ]

      run fn _input, _context -> {:ok, MyHiFi.Player.output()} end
    end

    action :select_output, :atom do
      description """
      Choose an output device.

      The choice stays after a restart, and the player starts the stream again, so
      a person hears the change at once.
      """

      argument :id, :string, allow_nil?: false

      run fn input, _context ->
        case MyHiFi.Player.select_output(input.arguments.id) do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  @doc """
  What the player is doing, or `idle/0` when it cannot say.

  A pipeline that crashes holds the player, and a caller that waited would stop with
  it. This waits one second, which is long enough for a player that is working and
  short enough that a person does not notice.
  """
  @spec state() :: map()
  def state do
    MyHiFi.Player.state(:timer.seconds(1))
  catch
    :exit, reason ->
      Logger.warning("The player did not say what it is doing: #{inspect(reason)}")

      idle()
  end

  @doc """
  The state of a player that plays nothing.

  A page draws this while the player is busy, and the next event of the player
  corrects it.
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
      standby?: false,
      position_ms: 0
    }
  end

  # An empty queue plays nothing, and `queue_playing` reads that as no row at all.
  defp playing_row do
    case MyHiFi.Playback.queue_playing!() do
      nil -> {:error, :nothing_to_play}
      row -> {:ok, row}
    end
  end
end
