defmodule MyHiFi.DeviceUi do
  @moduledoc """
  What the controls of the device do.

  A peripheral says that a person pressed a button, and this module decides what the
  press means. **The mapping lives here and nowhere else.** A peripheral names a
  button by its place on the board, because a board holds four buttons in a row and
  no label, and a device that changed the order of its controls would otherwise need
  a change in the driver of the hardware.

  The buttons of the PiTFT, in the order that they sit:

  | Button | What it does |
  | ------ | ------------ |
  | 1      | Standby, in and out |
  | 2      | The track before |
  | 3      | Play, or pause |
  | 4      | The track after |

  Standby is the leftmost, as it is on the web page, because a person who wants the
  device quiet reaches for the end of the row.

  The Pirate Audio holds two that answer, down the left of the screen:

  | Button | How long | What it does |
  | ------ | -------- | ------------ |
  | 1      | A tap    | Play, or pause |
  | 1      | A hold   | Standby, in and out |
  | 2      | A tap    | The track after |

  **Two buttons hold three controls, so one of them holds two.** A board of four has a
  button for standby and therefore reads no hold at all.

  The track before is the one that a person asks for least, so it is the one that no
  button holds.

  It uses `MyHiFi.Playback`, as the web interface does, so a press and a click take
  the same path.

  ## What it does not do yet

  This module is to hold the navigation of the device screen as well: the selected
  index, the list that a person moves through, and the `:view` and `:hint` events
  that go to a screen and to a knob. It holds the buttons alone for now, and the
  screen shows the now playing view alone.
  """

  use GenServer

  alias MyHiFi.Event
  alias MyHiFi.Event.Input
  alias MyHiFi.Peripheral
  alias MyHiFi.Playback

  require Logger

  @doc "Start reading the controls of the device."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  @impl GenServer
  def init(_opts) do
    Event.subscribe(:input)

    {:ok, %{}}
  end

  @doc false
  @impl GenServer
  def handle_info(%Input.ButtonPressed{} = event, state) do
    press(event.peripheral, event.button, event.hold)

    {:noreply, state}
  end

  # A knob and a touch panel send events of this topic as well, and each one arrives
  # here before the part of this module that reads it exists.
  def handle_info(%_{}, state), do: {:noreply, state}

  # **The board decides the meaning, so the event carries the board.** A row of four and
  # a pad of two cannot share one mapping, and the driver of a board must never hold the
  # meaning of a press.
  # **Two buttons hold three controls, so a hold of the first is the third.** A board of
  # four has a button for standby and needs no hold at all.
  defp press(Peripheral.PirateAudio, 1, :long), do: standby()
  defp press(Peripheral.PirateAudio, 1, :short), do: play_pause()
  defp press(Peripheral.PirateAudio, 2, :short), do: report(Playback.next())

  defp press(_row_of_four, 1, :short), do: standby()
  defp press(_row_of_four, 2, :short), do: report(Playback.previous())
  defp press(_row_of_four, 3, :short), do: play_pause()
  defp press(_row_of_four, 4, :short), do: report(Playback.next())

  # A board may hold more buttons than this device knows what to do with, and a hold of
  # a button that holds no second control is not a second control.
  defp press(_peripheral, _button, _hold), do: :ok

  defp standby do
    report(Playback.standby(not Playback.state!().standby?))
  end

  # The player holds the state, so this reads it and does not keep a copy. A press is
  # rare, and a copy that a missed event left behind would pause a track that plays.
  #
  # `playing?` says that the audio runs, and a pause of a track that is paused already
  # starts it again.
  defp play_pause do
    report(Playback.pause(Playback.state!().playing?))
  end

  # A control of a person must never stop this process. A press that cannot happen,
  # such as a next with nothing after it, is normal and the log holds the reason.
  defp report(:ok), do: :ok
  defp report({:ok, _result}), do: :ok
  defp report({:error, reason}), do: Logger.info("The control did nothing: #{inspect(reason)}")
end
