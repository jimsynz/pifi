defmodule PiFi.Peripheral.HapticKnobs do
  @moduledoc """
  The haptic knob board of
  [foc_peripheral](https://harton.dev/mypihifiguy/foc_peripheral): two gimbal motors
  that a person turns as knobs, and that push back with detents, end stops and clicks.

  The board hangs off the USB port as a serial device, and `FocPeripheral` speaks its
  protocol. This peripheral owns that connection and both knobs, because one serial
  port carries the two of them.

  **It sets how the knobs feel, and it says when they turn.** What a turn means is
  `PiFi.DeviceUi`'s to decide, so this publishes `PiFi.Event.Input.KnobTurned` and
  nothing else. The hints say which feel each knob needs:

  | Knob | Hint | Feel |
  | ---- | ---- | ---- |
  | 1 (left) | `PiFi.Event.Hint.Detents` with rows | One detent for each row, with end stops |
  | 1 (left) | `PiFi.Event.Hint.Detents` with none | A light click as it turns, and no stops |
  | 2 (right) | `PiFi.Event.Hint.Stepper` active | Three positions; back to the middle after each step |
  | 2 (right) | `PiFi.Event.Hint.Volume` adjustable | 0 to 100 at the level, with a tick at each step |
  | 2 (right) | otherwise | Limp |

  ## A knob that is turning keeps its own position

  Each turn reaches `PiFi.DeviceUi`, which answers with a hint that carries the position
  it acted on. **A hint for a knob that a person is turning is already out of date**: a
  fast turn of the level sends 40 while the knob is at 45, and a knob that took that
  hint would jump back under the hand and fight the person turning it. So the position
  of a hint reaches a knob only once that knob has been still for `:settle_ms`, or when
  the hint changes its shape, such as a menu level with another number of rows.

  This keeps the last position the board reported for each knob, and the positions
  that it set itself, so the board's report of a position that this set is not a turn.

  ## The board forgets

  A board that restarts goes back to its built-in settings, and says `@hello`. PiFi can
  restart while the board keeps running, too. Every setting therefore goes to the board
  again when the connection opens and when the board says hello.
  """

  @behaviour PiFi.Peripheral

  alias PiFi.Event
  alias PiFi.Event.Hint
  alias PiFi.Event.Input
  alias PiFi.Output.Volume

  @default_port "/dev/ttyUSB0"
  @default_settle_ms 500

  # The board numbers its knobs from 0, and PiFi numbers controls from 1.
  @left 0
  @right 1

  # The middle of the three positions of the stepper.
  @centre 1

  @doc "The name that the settings page draws."
  @impl PiFi.Peripheral
  def title, do: "Haptic knobs"

  @doc """
  Open the connection to the board and set both knobs.

  A board that is not plugged in is not a fault: `FocPeripheral` tries the port again
  every second, and the knobs are set when it opens.

  ## Options

  - `:port` - the serial port of the board. `#{@default_port}` by default.
  - `:settle_ms` - how long a knob must be still before a hint moves it.
    #{@default_settle_ms} by default.
  - `:connection` - a `FocPeripheral` that is already running, in the place of one
    that this starts. A test gives a fake board here.
  """
  @impl PiFi.Peripheral
  def init(opts) do
    connection = Keyword.get_lazy(opts, :connection, fn -> connect(opts) end)
    volume = Volume.state()

    state = %{
      connection: connection,
      settle_ms: Keyword.get(opts, :settle_ms, @default_settle_ms),
      detents: %Hint.Detents{},
      stepper?: false,
      volume: %Hint.Volume{
        percent: volume.percent,
        adjustable?: volume.enabled? and volume.supported?
      },
      positions: %{},
      turned_at: %{}
    }

    FocPeripheral.subscribe(connection)

    {:ok, set_both(state)}
  end

  @impl PiFi.Peripheral
  def subscriptions, do: [:hint]

  @impl PiFi.Peripheral
  def handle_event(%Hint.Detents{} = detents, state) do
    reshaped? = detents.count != state.detents.count
    state = %{state | detents: detents}

    if reshaped? or still?(state, @left),
      do: {:ok, set_left(state)},
      else: {:ok, state}
  end

  def handle_event(%Hint.Stepper{active?: active?}, %{stepper?: active?} = state),
    do: {:ok, state}

  def handle_event(%Hint.Stepper{active?: active?}, state),
    do: {:ok, set_right(%{state | stepper?: active?})}

  def handle_event(%Hint.Volume{} = volume, state) do
    reshaped? = volume.adjustable? != state.volume.adjustable?
    state = %{state | volume: volume}

    if not state.stepper? and (reshaped? or still?(state, @right)),
      do: {:ok, set_right(state)},
      else: {:ok, state}
  end

  def handle_event(_event, state), do: {:ok, state}

  @doc """
  Read what the board says.

  A move of a knob becomes `PiFi.Event.Input.KnobTurned`. A board that connects or
  restarts gets every setting again.
  """
  @impl PiFi.Peripheral
  def handle_info({FocPeripheral, {:position, index, position}}, state) do
    case Map.fetch(state.positions, index) do
      {:ok, ^position} -> {:ok, state}
      {:ok, known} -> {:ok, turned(state, index, position, position - known)}
      :error -> {:ok, put_in(state.positions[index], position)}
    end
  end

  def handle_info({FocPeripheral, :connected}, state), do: {:ok, set_both(state)}

  def handle_info({FocPeripheral, {:hello, _version}}, state), do: {:ok, set_both(state)}

  def handle_info({FocPeripheral, _event}, state), do: {:ok, state}

  @doc "Leave both knobs limp, so a knob that nothing reads says so by feel."
  @impl PiFi.Peripheral
  def terminate(_reason, state) do
    FocPeripheral.set(state.connection, @left, limp())
    FocPeripheral.set(state.connection, @right, limp())
    :ok
  end

  defp connect(opts) do
    {:ok, pid} = FocPeripheral.start_link(port: Keyword.get(opts, :port, @default_port))
    pid
  end

  defp turned(state, index, position, step) do
    Event.publish(:input, %Input.KnobTurned{
      peripheral: __MODULE__,
      knob: index + 1,
      position: position,
      step: step
    })

    state = %{
      state
      | positions: Map.put(state.positions, index, position),
        turned_at: Map.put(state.turned_at, index, now())
    }

    # A step of the stepper has been read, so the knob goes back to the middle, ready
    # for the next one. The shaft stays where it is: only its number changes.
    if index == @right and state.stepper?,
      do: set(state, @right, position: @centre),
      else: state
  end

  defp still?(state, index) do
    case Map.fetch(state.turned_at, index) do
      {:ok, at} -> now() - at >= state.settle_ms
      :error -> true
    end
  end

  defp set_both(state), do: state |> set_left() |> set_right()

  defp set_left(%{detents: %{count: 0}} = state) do
    set(state, @left, count: 0, width: 30.0, detent: 0.0, endstops: false, click: 1.0)
  end

  defp set_left(%{detents: detents} = state) do
    set(state, @left,
      count: detents.count,
      width: 30.0,
      detent: 1.5,
      endstops: true,
      endstop: 5.0,
      click: 0.0,
      position: detents.index
    )
  end

  defp set_right(%{stepper?: true} = state) do
    set(state, @right,
      count: 3,
      width: 30.0,
      detent: 2.0,
      endstops: true,
      endstop: 5.0,
      click: 0.0,
      position: @centre
    )
  end

  defp set_right(%{volume: %{adjustable?: true} = volume} = state) do
    set(state, @right,
      count: 101,
      width: 2.7,
      detent: 0.0,
      endstops: true,
      endstop: 5.0,
      click: 1.5,
      position: volume.percent
    )
  end

  defp set_right(state), do: set(state, @right, limp())

  # A knob that can do nothing turns freely and pushes back on nothing. Its steps are
  # wide, so turning it sends few reports that `PiFi.DeviceUi` would only ignore.
  defp limp, do: [count: 0, width: 30.0, detent: 0.0, endstops: false, click: 0.0]

  # A board that is not connected yet takes nothing, and it gets every setting when the
  # connection opens. See `handle_info/2`.
  defp set(state, index, settings) do
    FocPeripheral.set(state.connection, index, settings)

    case Keyword.fetch(settings, :position) do
      {:ok, position} -> put_in(state.positions[index], position)
      :error -> state
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
