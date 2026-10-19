defmodule PiFi.DeviceUi do
  # **How long a menu waits before it closes itself.** A person walks away from a
  # stereo, and a screen that held a list would say nothing about the track that plays.
  # Long enough to read a level of five rows and choose, and short enough that the
  # screen comes back before a person looks again.
  @close_after :timer.seconds(20)

  @moduledoc """
  What the controls of the device do.

  A peripheral says that a person pressed a button or turned a knob, along with the job
  that a person gave that control on the settings page. This module decides what each
  job does to the device. **It holds no table for any board.** Each board names its own
  defaults: see `PiFi.Peripheral.PiTft.button_jobs/0`,
  `PiFi.Peripheral.PirateAudio.button_jobs/0` and `PiFi.Peripheral.HapticKnobs`.

  A button press carries two jobs, one for the menu closed and one for it open. This
  module picks between them, because it's the only part that knows for certain whether
  the menu is open when the press arrives.

  | Job | What a press does |
  | --- | ----------------- |
  | Standby | Standby, in and out |
  | Previous track, next track | The track before or after |
  | Play or pause | Play, or pause |
  | Volume down, volume up | The level, 5% at a time |
  | Open the menu | Opens it where a person left it, if it's closed |
  | Back, row up, open or play the row, row down | Moves through the menu, if it's open |
  | Nothing | Nothing |

  **A press in standby wakes the device and does nothing else**, whatever its job,
  because a person can reassign every button and leave none on standby.

  A haptic knob's job decides its feel as well, so `PiFi.Peripheral.HapticKnobs` picks
  the job for the menu open or closed itself and `PiFi.Event.Input.KnobTurned` names
  only that one:

  | Job | Menu | What a turn does |
  | --- | ---- | ---------------- |
  | Open the menu | Closed | Opens it where a person left it |
  | Rows | Open | The position is the row, one detent each |
  | Back and forward | Open | A step left is back, a step right opens or plays the row |
  | Volume | Closed | The position is the level |
  | Jog | Closed | Skips within the track, further for a faster turn |

  By default the left knob opens the menu and moves through its rows, and the right one
  steps back and forward through it, and sets the level or jogs while it is closed.

  **The first turn of any knob in standby wakes the device and does nothing else**,
  because a device with knobs and no button has no other way out of standby.

  **Two knobs and no button carry the whole menu.** A knob has no press, so one becomes
  a switch of three positions while the menu is open. The hints say which feel each
  knob needs: `PiFi.Event.Hint.Menu`, `PiFi.Event.Hint.Detents`,
  `PiFi.Event.Hint.Volume` and `PiFi.Event.Hint.Scrub`.

  It uses `PiFi.Playback`, as the web interface does, so a press and a click take
  the same path.

  ## The menu

  **This module owns where a person is, and `PiFi.DeviceUi.Menu` owns the tree.** The
  state is a stack of levels: an open goes on the end of it, and a back takes one off.
  An empty stack is a closed menu.

  It publishes `PiFi.Event.View.MenuShown` for each move, so a screen draws the level
  and the row that a person is on, and it publishes `PiFi.Event.Hint.Detents` with the
  length of the level, because **a knob needs a detent count and only this module knows
  the length of the list**. See `PiFi.Peripheral`.

  **A menu that a person leaves open closes itself.** A person walks away from a stereo,
  and a screen that held a list would say nothing about the track that plays. The period
  is #{div(@close_after, 1000)} seconds, and each press starts it again.

  A press that plays closes the menu as well, because a person who chose a track wants
  to read what plays.

  **A menu opens where a person left it.** It keeps the path of the last one that
  closed, whatever closed it, and reads each level of that path again when it opens. A
  place that went away while the menu was closed ends the path there, so a source that
  was turned off opens the level above it. The path lasts until the firmware restarts.

  ## The screen that goes dark

  A device that runs on a battery plays an episode for two hours, and the screen
  shows a picture that no person reads for most of that time. The light is a large
  part of what the board takes from the cell, so this module turns it off after a
  period of no press and publishes `PiFi.Event.View.ScreenBlanked`. Each screen
  decides what dark means for it.

  **This is not standby.** `PiFi.AutoStandby` stops the audio, and it waits for
  quiet, so a track that plays keeps it off. This period runs while the audio plays,
  which is the case that costs the battery, and the audio continues.

  `PiFi.Playback.set_screen_blank_seconds/1` sets the period, and 0 turns it off. 0
  is what a new device uses, because a stereo on a shelf must keep showing what it
  plays. A person who carries the device sets a number.

  **The press that brings the screen back does nothing else.** A person who presses
  a button to read what plays must not skip the episode, so this module takes that
  press and stops.

  **A press in standby is not that press.** The screen is dark in standby as well,
  and the buttons are the only way out of it on a board that has no other control.
  This module therefore reads the player before it takes a press, and a press in
  standby goes through.
  """

  use GenServer

  alias PiFi.DeviceUi.Menu
  alias PiFi.Event
  alias PiFi.Event.Hint
  alias PiFi.Event.Input
  alias PiFi.Event.View
  alias PiFi.Playback
  alias PiFi.Settings

  require Logger

  # **How far one hold of a button moves the level.** A person holding a button gets one
  # step for each hold and not a run of them, because `PiFi.Peripheral.Buttons`
  # answers a long press one time. 5 percent therefore needs four holds to move a
  # quarter of the way, and a larger step would make the control too coarse to set.
  @volume_step 5

  # **How a jog wheel turns steps into time.** A step at 2 rad/s or slower moves 5
  # seconds, and one at 10 rad/s or faster moves a minute, with a straight line between.
  # These are a first guess, to tune by hand. The wait is how long the knob must be still
  # before its steps become one skip.
  @jog_slow 2.0
  @jog_fast 10.0
  @jog_slow_seconds 5
  @jog_fast_seconds 60
  @jog_settle_ms 175

  # **The longest period is an hour.** A person who wants a screen that stays lit
  # chooses 0 instead.
  @max_blank_seconds 3600

  # **A new device blanks no screen.** The two boards that this firmware drives are a
  # stereo component and a portable player, and only the second one gains from a dark
  # screen. A person who carries the device asks for the period.
  @default_blank_seconds 0

  @blank_key "screen.blank_seconds"

  @doc """
  Start reading the controls of the device.

  `:blank_ms` is the length of a second, and a test gives a small number for it. A
  period of 30 seconds cannot be measured in a test suite in any other way.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Where a person is in the menu, from the root down.

  It gives an empty list for a closed menu. A test reads this, and nothing of the
  firmware does: a screen reads `PiFi.Event.View.MenuShown` instead.
  """
  @spec places(GenServer.server()) :: [Menu.place()]
  def places(server \\ __MODULE__), do: GenServer.call(server, :places)

  @doc "The settings key of the period that the screen waits for."
  @spec blank_key() :: String.t()
  def blank_key, do: @blank_key

  @doc """
  The seconds of no press that the screen waits for before it goes dark.

  0 means that the screen stays lit.
  """
  @spec blank_seconds(GenServer.server()) :: non_neg_integer()
  def blank_seconds(server \\ __MODULE__), do: GenServer.call(server, :blank_seconds)

  @doc """
  Set the seconds of no press that the screen waits for before it goes dark.

  The value stays after a restart. 0 keeps the screen lit, and the longest period is
  #{@max_blank_seconds} seconds.
  """
  @spec set_blank_seconds(GenServer.server(), non_neg_integer()) ::
          :ok | {:error, :out_of_range}
  def set_blank_seconds(server \\ __MODULE__, seconds)

  def set_blank_seconds(server, seconds)
      when is_integer(seconds) and seconds in 0..@max_blank_seconds do
    GenServer.call(server, {:set_blank_seconds, seconds})
  end

  def set_blank_seconds(_server, _seconds), do: {:error, :out_of_range}

  @doc false
  @impl GenServer
  def init(opts) do
    Event.subscribe(:input)

    state = %{
      stack: [],
      remembered: [],
      timer: nil,
      blank_seconds: stored_blank_seconds(),
      blank_ms: Keyword.get(opts, :blank_ms, 1000),
      blank_timer: nil,
      blanked?: false,
      jog_ms: 0,
      jog_timer: nil
    }

    {:ok, hold_lit(state)}
  end

  @doc false
  @impl GenServer
  def handle_call(:places, _from, state) do
    {:reply, Enum.map(state.stack, & &1.place), state}
  end

  def handle_call(:blank_seconds, _from, state), do: {:reply, state.blank_seconds, state}

  # A period that a person shortens must take effect now, and not after the period that
  # is already running, so this starts the new one and lights the screen.
  def handle_call({:set_blank_seconds, seconds}, _from, state) do
    Settings.put(@blank_key, to_string(seconds))

    {:reply, :ok, %{state | blank_seconds: seconds} |> unblank() |> hold_lit()}
  end

  @doc false
  @impl GenServer
  # **A press in standby wakes the device and does nothing else**, as a turn of a knob
  # does. A person can give every button a job, and one that left no button on standby
  # would leave no way out of it.
  def handle_info(%Input.ButtonPressed{} = event, state) do
    state =
      if Playback.state!().standby?,
        do: wake(state),
        else: press(event, state)

    {:noreply, hold_lit(state)}
  end

  # The menu closes itself, and a press that arrived in the moment before this message
  # started the period again. See `@close_after`.
  def handle_info(:close_menu, state), do: {:noreply, close(state)}

  # **A device in standby is dark already, and it must not become blanked.** The dark of
  # standby and the dark of this timer look the same to a person, and they do not mean
  # the same thing to a press: a press in standby leaves standby, and a press of a
  # blanked screen does nothing. A read of the player is what keeps the two apart, and
  # this process keeps no copy of it.
  def handle_info(:blank, state) do
    state = %{state | blank_timer: nil}

    if Playback.state!().standby? do
      {:noreply, hold_lit(state)}
    else
      {:noreply, blank(state)}
    end
  end

  # **The first turn in standby wakes the device and does nothing else.** A device
  # whose only controls are knobs has no other way out of standby, and a turn that woke
  # it must not also open the menu or move the level behind a screen that is still
  # coming on. The player owns the state, so this reads it rather than keep a copy.
  def handle_info(%Input.KnobTurned{} = event, state) do
    state =
      if Playback.state!().standby?,
        do: wake(state),
        else: turn(event.function, event, state)

    {:noreply, hold_lit(state)}
  end

  # The jog wheel has stopped for long enough: the steps it took become one skip.
  def handle_info(:jog, state) do
    report(Playback.skip(state.jog_ms))
    {:noreply, %{state | jog_ms: 0, jog_timer: nil}}
  end

  # A touch panel sends events of this topic as well, and each one arrives here before
  # the part of this module that reads it exists.
  def handle_info(%_{}, state), do: {:noreply, state}

  # **The first press after the screen went dark brings it back and does nothing else.**
  # A person who presses a button to read what plays must not skip the episode.
  defp press(_event, %{blanked?: true} = state), do: unblank(state)

  # **A press carries the job for the menu closed and the one for it open**, and this
  # picks, because it is the one part that knows which holds now. Each board names what
  # its buttons do until a person changes it: see `PiFi.Peripheral.PiTft.button_jobs/0`
  # and `PiFi.Peripheral.PirateAudio.button_jobs/0`.
  defp press(event, %{stack: []} = state), do: job(event.function, state)
  defp press(event, state), do: job(event.menu_function, state)

  defp job(:standby, state), do: doing(state, fn -> standby() end)
  defp job(:previous, state), do: doing(state, fn -> report(Playback.previous()) end)
  defp job(:play_pause, state), do: doing(state, fn -> play_pause() end)
  defp job(:next, state), do: doing(state, fn -> report(Playback.next()) end)
  defp job(:volume_down, state), do: doing(state, fn -> step_volume(-@volume_step) end)
  defp job(:volume_up, state), do: doing(state, fn -> step_volume(@volume_step) end)
  defp job(:open_menu, %{stack: []} = state), do: open(state)

  # The four moves of a level do nothing with the menu closed: a person can give them
  # to a press of the closed menu, and there is no list for them to move through.
  defp job(:back, %{stack: [_ | _]} = state), do: back(state)
  defp job(:row_up, %{stack: [_ | _]} = state), do: move(state, -1)
  defp job(:select, %{stack: [_ | _]} = state), do: select(state)
  defp job(:row_down, %{stack: [_ | _]} = state), do: move(state, 1)
  defp job(_nothing_here, state), do: state

  # A job that acts on the player and leaves the menu as it is.
  defp doing(state, action) do
    action.()
    state
  end

  # **The first turn of a blanked screen lights it and does nothing else**, for the same
  # reason as the first press.
  defp turn(_function, _event, %{blanked?: true} = state), do: unblank(state)

  # **A knob names its job, so this reads the job and not the knob.** A person gives each
  # knob its jobs on the settings page, and the peripheral names the one that holds now.
  # The menu can open or close between the turn and this, so each job checks it too.
  # See `PiFi.Event.Input.KnobTurned`.
  defp turn(:open_menu, _event, %{stack: []} = state), do: open(state)
  defp turn(:rows, event, %{stack: [_ | _]} = state), do: move_to(state, event.position)

  # A step left is back and a step right opens or plays the row, so a person with two
  # knobs and no button can use the whole menu.
  defp turn(:back_forward, %{step: step}, %{stack: [_ | _]} = state) when step < 0,
    do: back(state)

  defp turn(:back_forward, %{step: step}, %{stack: [_ | _]} = state) when step > 0,
    do: select(state)

  defp turn(:volume, event, %{stack: []} = state) do
    set_volume(event.position)
    state
  end

  defp turn(:jog, event, %{stack: []} = state), do: jog(state, event)

  defp turn(_function, _event, state), do: state

  # **A jog wheel collects its steps and skips once, when the hand stops.** Each step
  # would otherwise start a skip of its own, and a skip of FLAC bisects the file. A step
  # moves further for a faster turn: a slow turn finds a place a few seconds at a time,
  # and a flick crosses minutes.
  defp jog(state, event) do
    if state.jog_timer, do: Process.cancel_timer(state.jog_timer)

    %{
      state
      | jog_ms: state.jog_ms + event.step * jog_step_ms(event.velocity),
        jog_timer: Process.send_after(self(), :jog, @jog_settle_ms)
    }
  end

  defp jog_step_ms(velocity) do
    speed = abs(velocity)
    share = (speed - @jog_slow) / (@jog_fast - @jog_slow)
    seconds = @jog_slow_seconds + (@jog_fast_seconds - @jog_slow_seconds) * min(max(share, 0), 1)
    round(seconds * 1000)
  end

  # **The ends of a level are stops, and the list does not go round.** A knob with
  # detents reads the count of this level, and a detent that ran past the end of the
  # list would turn for ever. See `PiFi.Event.Hint.Detents`.
  defp move(state, step), do: move_to(state, List.last(state.stack).index + step)

  defp move_to(state, index) do
    {above, [current]} = Enum.split(state.stack, -1)
    last = length(current.rows) - 1
    index = index |> Kernel.max(0) |> Kernel.min(Kernel.max(last, 0))

    announce(%{state | stack: above ++ [%{current | index: index}]})
  end

  # A level of no rows takes a press and does nothing. A country that a sync emptied
  # while a person read it is one way to meet that.
  defp select(state) do
    current = List.last(state.stack)

    case Enum.at(current.rows, current.index) do
      nil -> state
      row -> act(row.action, state)
    end
  end

  defp act({:open, place}, state), do: state |> push(place) |> announce()

  defp act(:close, state), do: close(state)

  # A row that says something and does nothing. `PiFi.DeviceUi.Menu` draws one for a
  # source that receives audio, because a level with no row reads as a broken source.
  defp act(:none, state), do: state

  defp act(:standby, state) do
    standby()

    close(state)
  end

  # **A press that plays leaves the menu.** A person who chose a track wants to read
  # what plays, and the now playing view is what says it.
  defp act({:play, ids, index}, state) do
    report(Playback.play(ids, %{playing_index: index}))

    close(state)
  end

  # The root is the level that leaves the menu, so a back from it is a close.
  defp back(state) do
    case Enum.split(state.stack, -1) do
      {[], _root} -> close(state)
      {above, _leaving} -> announce(%{state | stack: above})
    end
  end

  defp push(state, place) do
    entry = place |> Menu.level() |> Map.put(:index, 0)

    %{state | stack: state.stack ++ [entry]}
  end

  # **A menu opens where a person left it.** One step of a knob too many at the root
  # closes the menu, and a person who opens it again wants the row they were on, and not
  # the top of the list they had scrolled through.
  defp open(%{remembered: []} = state), do: state |> push(:root) |> announce()

  defp open(state) do
    case restore(state.remembered) do
      [] -> state |> push(:root) |> announce()
      stack -> announce(%{state | stack: stack})
    end
  end

  # Each level is read again, because a list changes while the menu is closed, and each
  # row is held inside the new length. **A place that no longer exists ends the path
  # there**: `PiFi.DeviceUi.Menu.level/1` gives the root for it, and a level below the
  # root that came back as the root is a source that was turned off or a container that
  # went away.
  defp restore(remembered) do
    Enum.reduce_while(remembered, [], fn {place, index}, stack ->
      case Menu.level(place) do
        %{place: ^place} = level ->
          last = Kernel.max(length(level.rows) - 1, 0)
          {:cont, stack ++ [Map.put(level, :index, Kernel.min(index, last))]}

        _gone ->
          {:halt, stack}
      end
    end)
  end

  defp wake(state) do
    report(Playback.standby(false))
    state
  end

  # **A screen reads the whole level, and it draws the part that fits.** This module
  # knows no size of a screen, and a screen knows how many rows it can draw. The hint
  # carries the count for a knob, which needs one detent for each row.
  defp announce(state) do
    current = List.last(state.stack)

    Event.publish(:view, %View.MenuShown{
      title: current.title,
      rows: Enum.map(current.rows, &Map.take(&1, [:title, :subtitle, :kind])),
      index: current.index,
      depth: length(state.stack) - 1
    })

    Event.publish(:hint, %Hint.Detents{count: length(current.rows), index: current.index})
    Event.publish(:hint, %Hint.Menu{open?: true})

    hold_open(state)
  end

  # A menu that is closed already needs no event: the screen draws what plays, and a
  # second `MenuClosed` would make it draw that again.
  defp close(%{stack: []} = state), do: state

  defp close(state) do
    Event.publish(:view, %View.MenuClosed{})
    Event.publish(:hint, %Hint.Detents{count: 0, index: 0})
    Event.publish(:hint, %Hint.Menu{open?: false})

    remembered = Enum.map(state.stack, &{&1.place, &1.index})
    let_go(%{state | stack: [], remembered: remembered})
  end

  defp hold_open(state) do
    state = let_go(state)

    %{state | timer: Process.send_after(self(), :close_menu, @close_after)}
  end

  defp let_go(%{timer: nil} = state), do: state

  defp let_go(state) do
    Process.cancel_timer(state.timer)

    %{state | timer: nil}
  end

  # A screen that is lit stays lit for the period, and each press starts the period
  # again. A period of 0 is a person who asked for a screen that never goes dark.
  defp hold_lit(%{blank_seconds: 0} = state), do: let_dark(state)

  defp hold_lit(state) do
    state = let_dark(state)

    %{
      state
      | blank_timer: Process.send_after(self(), :blank, state.blank_seconds * state.blank_ms)
    }
  end

  # `Process.cancel_timer/1` can arrive too late, and the message of a timer that already
  # fired then waits in the mailbox. A read of it here keeps the screen from going dark
  # in the moment after a person pressed a button. See `PiFi.AutoStandby`.
  defp let_dark(%{blank_timer: nil} = state), do: state

  defp let_dark(state) do
    Process.cancel_timer(state.blank_timer)

    receive do
      :blank -> :ok
    after
      0 -> :ok
    end

    %{state | blank_timer: nil}
  end

  defp blank(%{blanked?: true} = state), do: state

  defp blank(state) do
    Event.publish(:view, %View.ScreenBlanked{blanked?: true})

    %{state | blanked?: true}
  end

  defp unblank(%{blanked?: false} = state), do: state

  defp unblank(state) do
    Event.publish(:view, %View.ScreenBlanked{blanked?: false})

    %{state | blanked?: false}
  end

  # A person who set no period gets a screen that stays lit. A row that carries
  # something that is not a number is a row that no part of this firmware writes, and
  # the default is a better answer than a process that will not start.
  defp stored_blank_seconds do
    with {:ok, %{value: value}} <- Settings.fetch(@blank_key),
         {seconds, ""} when seconds in 0..@max_blank_seconds <- Integer.parse(value) do
      seconds
    else
      _other -> @default_blank_seconds
    end
  end

  # **A button that a person holds moves the level, and it reads the level first.** The
  # player keeps no copy of it, and `PiFi.Output.Volume` is the one place that does,
  # so a missed event cannot leave this moving from the wrong number.
  #
  # A press that reaches a card with no level does nothing that a person can hear, and
  # the log names the reason. See `PiFi.Output.Volume`.
  defp step_volume(step) do
    case Playback.volume!() do
      %{enabled?: true, percent: percent} ->
        report(Playback.set_volume(clamp(percent + step)))

      _other ->
        :ok
    end
  end

  # A knob sets the level outright, and it reads whether the control is on first, as a
  # held button does. A knob that turns while the control is off is limp and moves
  # nothing that a person can hear. See `PiFi.Event.Hint.Volume`.
  defp set_volume(percent) do
    case Playback.volume!() do
      %{enabled?: true} -> report(Playback.set_volume(clamp(percent)))
      _other -> :ok
    end
  end

  defp clamp(percent), do: percent |> max(0) |> min(100)

  defp standby do
    report(Playback.standby(not Playback.state!().standby?))
  end

  # The player owns the state, so this reads it and does not keep a copy. A press is
  # rare, and a copy that a missed event left behind would pause a track that plays.
  #
  # `playing?` says that the audio runs, and a pause of a track that is paused already
  # starts it again.
  defp play_pause do
    report(Playback.pause(Playback.state!().playing?))
  end

  # A control of a person must never stop this process. A press that cannot happen,
  # such as a next with nothing after it, is normal and the log names the reason.
  defp report(:ok), do: :ok
  defp report({:ok, _result}), do: :ok
  defp report({:error, reason}), do: Logger.info("The control did nothing: #{inspect(reason)}")
end
