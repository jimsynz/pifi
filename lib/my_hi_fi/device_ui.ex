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
  def handle_info(%Input.ButtonPressed{button: button}, state) do
    press(button)

    {:noreply, state}
  end

  # A knob and a touch panel send events of this topic as well, and each one arrives
  # here before the part of this module that reads it exists.
  def handle_info(%_{}, state), do: {:noreply, state}

  defp press(1), do: standby()
  defp press(2), do: report(Playback.previous())
  defp press(3), do: play_pause()
  defp press(4), do: report(Playback.next())

  # A board may hold more buttons than this device knows what to do with.
  defp press(_button), do: :ok

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
