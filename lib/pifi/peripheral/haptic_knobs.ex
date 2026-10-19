defmodule PiFi.Peripheral.HapticKnobs do
  @moduledoc """
  The haptic knob board of
  [foc_peripheral](https://harton.dev/mypihifiguy/foc_peripheral): one or two gimbal
  motors that a person turns as knobs, and that push back with detents, end stops and
  clicks.

  The board hangs off the USB port as a serial device, and `FocPeripheral` speaks its
  protocol. This peripheral owns that connection and every knob on it, because one
  serial port carries them all.

  ## A person gives each knob its jobs

  Each knob has one job while the menu is closed and one while it is open, and a person
  chooses both on the settings page:

  | Job | Menu | Feel |
  | --- | ---- | ---- |
  | Open the menu | Closed | A light click as it turns, and no stops |
  | Volume | Closed | 0 to 100 at the level, with a tick at each step |
  | Jog | Closed | Light detents and a click, and no stops |
  | Volume, or jog | Closed | Volume while volume control is on, jog while it is off |
  | Rows | Open | One detent for each row, with end stops |
  | Back and forward | Open | Three positions; back to the middle after each step |
  | Nothing | Either | Limp |

  **A job that can do nothing goes limp**, so a person feels that the knob isn't in
  charge: volume while volume control is off, a jog through a radio stream or a paused
  track, and rows of a level that has none.

  **It sets how the knobs feel, and it says when they turn.** A knob names its job in
  `PiFi.Event.Input.KnobTurned`, unlike a button, because a person labelled it on the
  settings page and its feel has to match. What each job does to the device is still
  `PiFi.DeviceUi`'s to decide. The hints say what each job needs to know:
  `PiFi.Event.Hint.Menu` for which job holds, `PiFi.Event.Hint.Detents` for the rows,
  `PiFi.Event.Hint.Volume` for the level and `PiFi.Event.Hint.Scrub` for the jog.

  ## A knob that is turning keeps its own position

  Each turn reaches `PiFi.DeviceUi`, which answers with a hint that carries the position
  it acted on. **A hint for a knob that a person is turning is already out of date**: a
  fast turn of the level sends 40 while the knob is at 45, and a knob that took that
  hint would jump back under the hand and fight the person turning it. So the position
  of a hint reaches a knob only once that knob has been still for `:settle_ms`, or when
  the hint changes its job or its shape, such as a menu level with another number of
  rows.

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
  alias PiFi.Player
  alias PiFi.Settings

  @default_port "/dev/ttyUSB0"
  @default_settle_ms 500

  # The board numbers its knobs from 0, left to right, and PiFi numbers controls from 1.
  @knobs [0, 1]

  # The middle of the three positions of back and forward.
  @centre 1

  @closed_jobs [
    {"open_menu", "Open the menu"},
    {"volume", "Volume"},
    {"jog", "Jog through the track"},
    {"volume_or_jog", "Volume, or jog when volume control is off"},
    {"none", "Nothing"}
  ]

  @open_jobs [
    {"rows", "Move through the rows"},
    {"back_forward", "Back and forward"},
    {"none", "Nothing"}
  ]

  @knob_counts [{"2", "Two"}, {"1", "One"}]

  # Each setting, its choices, and what a new device does. The defaults are the left
  # knob on the menu and the right one on back and forward, and the level or a jog.
  @settings [
    {"knobs", "Knobs", "How many knobs your board has.", @knob_counts, "2"},
    {"left_closed", "Left knob, menu closed", nil, @closed_jobs, "open_menu"},
    {"left_open", "Left knob, menu open", nil, @open_jobs, "rows"},
    {"right_closed", "Right knob, menu closed", nil, @closed_jobs, "volume_or_jog"},
    {"right_open", "Right knob, menu open", nil, @open_jobs, "back_forward"}
  ]

  @doc "The name that the settings page draws."
  @impl PiFi.Peripheral
  def title, do: "Haptic knobs"

  @doc "How many knobs the board has, and the jobs of each one. See the module docs."
  @impl PiFi.Peripheral
  def settings do
    Enum.map(@settings, fn {key, title, description, options, _default} ->
      %{
        key: key,
        title: title,
        description: description,
        link: nil,
        type: :select,
        options: options,
        value: stored(key),
        write_only?: false
      }
    end)
  end

  @doc "Keep the knobs' settings. Each value must be one of its field's choices."
  @impl PiFi.Peripheral
  def put_settings(values) do
    chosen =
      for {key, _title, _description, options, _default} <- @settings,
          Map.has_key?(values, key),
          do: {key, values[key], options}

    if Enum.all?(chosen, fn {_key, value, options} -> List.keymember?(options, value, 0) end) do
      Enum.each(chosen, fn {key, value, _options} -> Settings.put!(setting_key(key), value) end)
      {:ok, "Saved the knobs."}
    else
      {:error, "That isn't a choice the knobs have."}
    end
  end

  @doc """
  Open the connection to the board and set every knob.

  A board that is not plugged in is not a fault: `FocPeripheral` tries the port again
  every second, and the knobs are set when it opens. It reads its settings here, and
  `PiFi.Peripheral.put_settings/2` starts it again after a save.

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
      count: String.to_integer(stored("knobs")),
      jobs: %{
        0 => {job(stored("left_closed")), job(stored("left_open"))},
        1 => {job(stored("right_closed")), job(stored("right_open"))}
      },
      menu_open?: false,
      detents: %Hint.Detents{},
      volume: %Hint.Volume{
        percent: volume.percent,
        adjustable?: volume.enabled? and volume.supported?
      },
      scrub?: Player.scrubbable?(),
      functions: %{},
      positions: %{},
      turned_at: %{}
    }

    FocPeripheral.subscribe(connection)

    {:ok, set_all(state)}
  end

  @impl PiFi.Peripheral
  def subscriptions, do: [:hint]

  @impl PiFi.Peripheral
  def handle_event(%Hint.Menu{open?: open?}, state),
    do: {:ok, follow(%{state | menu_open?: open?})}

  def handle_event(%Hint.Scrub{available?: available?}, state),
    do: {:ok, follow(%{state | scrub?: available?})}

  # A new number of rows reshapes a knob of rows, and the row alone moves one that is
  # still. See "A knob that is turning keeps its own position".
  def handle_event(%Hint.Detents{} = detents, state) do
    reshaped? = detents.count != state.detents.count
    state = follow(%{state | detents: detents})

    {:ok, set_moved(state, :rows, reshaped?)}
  end

  def handle_event(%Hint.Volume{} = volume, state) do
    {:ok, state |> Map.put(:volume, volume) |> follow() |> set_moved(:volume, false)}
  end

  def handle_event(_event, state), do: {:ok, state}

  @doc """
  Read what the board says.

  A move of a knob becomes `PiFi.Event.Input.KnobTurned`. A board that connects or
  restarts gets every setting again.
  """
  @impl PiFi.Peripheral
  def handle_info({FocPeripheral, {:position, index, position, velocity}}, state)
      when index < state.count do
    case Map.fetch(state.positions, index) do
      {:ok, ^position} -> {:ok, state}
      {:ok, known} -> {:ok, turned(state, index, position, position - known, velocity)}
      :error -> {:ok, put_in(state.positions[index], position)}
    end
  end

  def handle_info({FocPeripheral, :connected}, state), do: {:ok, set_all(state)}

  def handle_info({FocPeripheral, {:hello, _protocol, _firmware}}, state),
    do: {:ok, set_all(state)}

  def handle_info({FocPeripheral, _event}, state), do: {:ok, state}

  @doc "Leave every knob limp, so a knob that nothing reads says so by feel."
  @impl PiFi.Peripheral
  def terminate(_reason, state) do
    Enum.each(@knobs, &FocPeripheral.set(state.connection, &1, limp()))
  end

  # **The board is brought to the firmware this build ships, when it starts.** Its
  # firmware and the `foc_peripheral` library are two halves of one protocol, so a
  # board from an older PiFi, a blank one, or one that ran another project is flashed
  # before the knobs are used. `FocPeripheral` writes nothing to a chip that isn't a
  # classic ESP32, flashes at most once, and the knobs are limp while it works.
  defp connect(opts) do
    {:ok, pid} =
      FocPeripheral.start_link(port: Keyword.get(opts, :port, @default_port), firmware: :ensure)

    pid
  end

  defp turned(state, index, position, step, velocity) do
    function = Map.get(state.functions, index, :none)

    Event.publish(:input, %Input.KnobTurned{
      peripheral: __MODULE__,
      knob: index + 1,
      function: function,
      position: position,
      step: step,
      velocity: velocity
    })

    state = %{
      state
      | positions: Map.put(state.positions, index, position),
        turned_at: Map.put(state.turned_at, index, now())
    }

    # A step of back and forward has been read, so the knob goes back to the middle,
    # ready for the next one. The shaft stays where it is: only its number changes.
    if function == :back_forward,
      do: set(state, index, position: @centre),
      else: state
  end

  # Work out what each knob does now, and give a knob whose job changed its new feel at
  # once: a new job is a new shape, whatever the hand is doing.
  defp follow(state) do
    Enum.reduce(knobs(state), state, fn index, state ->
      function = function(state, index)

      if Map.get(state.functions, index) == function,
        do: state,
        else: state |> put_in([:functions, index], function) |> set_feel(index)
    end)
  end

  # A hint that moves a value: every knob doing `function` takes the new shape when
  # `reshaped?`, and the new position only when the hand has left it. A knob that
  # `follow/1` just gave this job gets its feel a second time here, which the board
  # takes as the same settings again.
  defp set_moved(state, function, reshaped?) do
    Enum.reduce(knobs(state), state, fn index, state ->
      if state.functions[index] == function and (reshaped? or still?(state, index)),
        do: set_feel(state, index),
        else: state
    end)
  end

  defp set_all(state) do
    state = Enum.reduce(knobs(state), state, &put_in(&2, [:functions, &1], function(&2, &1)))
    state = Enum.reduce(knobs(state), state, &set_feel(&2, &1))

    # A knob the board has and the person said it hasn't does nothing at all.
    Enum.reduce(Enum.drop(@knobs, state.count), state, &set(&2, &1, limp()))
  end

  defp knobs(state), do: Enum.take(@knobs, state.count)

  defp function(state, index) do
    {closed, open} = state.jobs[index]
    resolve(if(state.menu_open?, do: open, else: closed), state)
  end

  defp resolve(:volume_or_jog, %{volume: %{adjustable?: true}}), do: :volume
  defp resolve(:volume_or_jog, %{scrub?: true}), do: :jog
  defp resolve(:volume_or_jog, _state), do: :none
  defp resolve(:volume, %{volume: %{adjustable?: false}}), do: :none
  defp resolve(:jog, %{scrub?: false}), do: :none
  defp resolve(:rows, %{detents: %{count: 0}}), do: :none
  defp resolve(job, _state), do: job

  defp set_feel(state, index), do: set(state, index, feel(state.functions[index], state))

  defp feel(:open_menu, _state),
    do: [count: 0, width: 30.0, detent: 0.0, endstops: false, click: 1.0]

  defp feel(:rows, state) do
    [
      count: state.detents.count,
      width: 30.0,
      detent: 1.5,
      endstops: true,
      endstop: 5.0,
      click: 0.0,
      position: state.detents.index
    ]
  end

  defp feel(:back_forward, _state) do
    [
      count: 3,
      width: 30.0,
      detent: 2.0,
      endstops: true,
      endstop: 5.0,
      click: 0.0,
      position: @centre
    ]
  end

  defp feel(:volume, state) do
    [
      count: 101,
      width: 2.7,
      detent: 0.0,
      endstops: true,
      endstop: 5.0,
      click: 1.5,
      position: state.volume.percent
    ]
  end

  defp feel(:jog, _state),
    do: [count: 0, width: 15.0, detent: 0.6, endstops: false, click: 1.0]

  defp feel(:none, _state), do: limp()

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

  defp still?(state, index) do
    case Map.fetch(state.turned_at, index) do
      {:ok, at} -> now() - at >= state.settle_ms
      :error -> true
    end
  end

  # A value that is no longer one of the choices, such as a job that a later version
  # dropped, reads as the default rather than stop the knobs from starting.
  defp stored(key) do
    {^key, _title, _description, options, default} = List.keyfind(@settings, key, 0)

    case Settings.fetch(setting_key(key)) do
      {:ok, %{value: value}} -> if List.keymember?(options, value, 0), do: value, else: default
      _unset -> default
    end
  end

  defp setting_key(key), do: "peripheral.haptic-knobs." <> key

  # The values come from `stored/1`, which holds each one to its choices.
  defp job("open_menu"), do: :open_menu
  defp job("volume"), do: :volume
  defp job("jog"), do: :jog
  defp job("volume_or_jog"), do: :volume_or_jog
  defp job("rows"), do: :rows
  defp job("back_forward"), do: :back_forward
  defp job("none"), do: :none

  defp now, do: System.monotonic_time(:millisecond)
end
