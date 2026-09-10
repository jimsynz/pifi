defmodule MyHiFi.DeviceUi do
  # **How long a menu waits before it closes itself.** A person walks away from a
  # stereo, and a screen that held a list would say nothing about the track that plays.
  # Long enough to read a level of five rows and choose, and short enough that the
  # screen comes back before a person looks again.
  @close_after :timer.seconds(20)

  @moduledoc """
  What the controls of the device do.

  A peripheral says that a person pressed a button, and this module decides what the
  press means. **The mapping lives here and nowhere else.** A peripheral names a
  button by its place on the board, because a board has four buttons in a row and
  no label, and a device that changed the order of its controls would otherwise need
  a change in the driver of the hardware.

  The buttons of the PiTFT, in the order that they sit:

  | Button | What it does | A hold |
  | ------ | ------------ | ------ |
  | 1      | Standby, in and out | |
  | 2      | The track before | The level down |
  | 3      | Play, or pause | The menu |
  | 4      | The track after | The level up |

  Standby is the leftmost, as it is on the web page, because a person who wants the
  device quiet reaches for the end of the row.

  The same four buttons carry the menu while the menu is open:

  | Button | What it does |
  | ------ | ------------ |
  | 1      | Back, and out of the menu at the root |
  | 2      | The row above |
  | 3      | Open the row, or play it |
  | 4      | The row below |

  **The row of four is the board that draws a menu.** A board of two buttons carries
  three controls of the transport already, and a tree needs four: up, down, in and out.
  The Pirate Audio therefore keeps the controls that it has.

  The Pirate Audio has two that answer, down the left of the screen:

  | Button | How long | What it does |
  | ------ | -------- | ------------ |
  | 1      | A tap    | Play, or pause |
  | 1      | A hold   | Standby, in and out |
  | 2      | A tap    | The track after |

  **Two buttons carry three controls, so one of them carries two.** A board of four has a
  button for standby and therefore reads no hold at all.

  The track before is the one that a person asks for least, so it is the one that no
  button carries.

  It uses `MyHiFi.Playback`, as the web interface does, so a press and a click take
  the same path.

  ## The menu

  **This module owns where a person is, and `MyHiFi.DeviceUi.Menu` owns the tree.** The
  state is a stack of levels: an open goes on the end of it, and a back takes one off.
  An empty stack is a closed menu.

  It publishes `MyHiFi.Event.View.MenuShown` for each move, so a screen draws the level
  and the row that a person is on, and it publishes `MyHiFi.Event.Hint.Detents` with the
  length of the level, because **a knob needs a detent count and only this module knows
  the length of the list**. See `MyHiFi.Peripheral`.

  **A menu that a person leaves open closes itself.** A person walks away from a stereo,
  and a screen that held a list would say nothing about the track that plays. The period
  is #{div(@close_after, 1000)} seconds, and each press starts it again.

  A press that plays closes the menu as well, because a person who chose a track wants
  to read what plays.
  """

  use GenServer

  alias MyHiFi.DeviceUi.Menu
  alias MyHiFi.Event
  alias MyHiFi.Event.Hint
  alias MyHiFi.Event.Input
  alias MyHiFi.Event.View
  alias MyHiFi.Peripheral
  alias MyHiFi.Playback

  require Logger

  # **How far one hold of a button moves the level.** A person holding a button gets one
  # step for each hold and not a run of them, because `MyHiFi.Peripheral.Buttons`
  # answers a long press one time. 5 percent therefore needs four holds to move a
  # quarter of the way, and a larger step would make the control too coarse to set.
  @volume_step 5

  @doc "Start reading the controls of the device."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Where a person is in the menu, from the root down.

  It gives an empty list for a closed menu. A test reads this, and nothing of the
  firmware does: a screen reads `MyHiFi.Event.View.MenuShown` instead.
  """
  @spec places(GenServer.server()) :: [Menu.place()]
  def places(server \\ __MODULE__), do: GenServer.call(server, :places)

  @doc false
  @impl GenServer
  def init(_opts) do
    Event.subscribe(:input)

    {:ok, %{stack: [], timer: nil}}
  end

  @doc false
  @impl GenServer
  def handle_call(:places, _from, state) do
    {:reply, Enum.map(state.stack, & &1.place), state}
  end

  @doc false
  @impl GenServer
  def handle_info(%Input.ButtonPressed{} = event, state) do
    {:noreply, press(event.peripheral, event.button, event.hold, state)}
  end

  # The menu closes itself, and a press that arrived in the moment before this message
  # started the period again. See `@close_after`.
  def handle_info(:close_menu, state), do: {:noreply, close(state)}

  # A knob and a touch panel send events of this topic as well, and each one arrives
  # here before the part of this module that reads it exists.
  def handle_info(%_{}, state), do: {:noreply, state}

  # **The board decides the meaning, so the event carries the board.** A row of four and
  # a pad of two cannot share one mapping, and the driver of a board must never hold the
  # meaning of a press.
  #
  # **A board of two buttons reads no menu.** Its three controls of the transport take
  # every press that it has, and a tree needs four: up, down, in and out.
  defp press(Peripheral.PirateAudio, button, hold, state) do
    pirate_audio(button, hold)

    state
  end

  # The menu takes the row of four while it is open, and the transport takes it while
  # the menu is closed.
  defp press(_row_of_four, button, hold, %{stack: []} = state) do
    case transport(button, hold) do
      :open_menu -> state |> push(:root) |> announce()
      _other -> state
    end
  end

  defp press(_row_of_four, button, hold, state), do: menu(button, hold, state)

  # **Two buttons carry three controls, so a hold of the first is the third.** A board of
  # four has a button for standby and needs no hold at all.
  defp pirate_audio(1, :long), do: standby()
  defp pirate_audio(1, :short), do: play_pause()
  defp pirate_audio(2, :short), do: report(Playback.next())
  defp pirate_audio(_button, _hold), do: :ok

  defp transport(1, :short), do: standby()
  defp transport(2, :short), do: report(Playback.previous())
  defp transport(3, :short), do: play_pause()
  defp transport(4, :short), do: report(Playback.next())

  # **A hold of the track buttons moves the level.** A row of four carries every control
  # that this device needs on a short press already, and a hold of one of them held no
  # control at all, so the level costs no control that a person had. It sits on the two
  # that move through the tracks, because down and up must sit beside each other and in
  # that order, and 2 and 4 are the two that already mean back and forward.
  #
  # A hold of 1 is absent on purpose: a hold of the standby button on a stereo means
  # nothing, and the Pirate Audio uses it for standby itself.
  defp transport(2, :long), do: step_volume(-@volume_step)
  defp transport(4, :long), do: step_volume(@volume_step)

  # **A hold of the play button opens the menu.** It is the one hold of a row of four
  # that carried nothing: 1 is absent on purpose, and 2 and 4 move the level. A person
  # holds the button in the middle of the transport to leave the transport.
  defp transport(3, :long), do: :open_menu

  # A board may hold more buttons than this device knows what to do with, and a hold of
  # a button with no second control is not a second control.
  defp transport(_button, _hold), do: :ok

  # The four controls of a level. A hold while the menu is open carries nothing: a
  # person in a list is choosing a row, and the level of the volume is not what they
  # came for.
  defp menu(1, :short, state), do: back(state)
  defp menu(2, :short, state), do: move(state, -1)
  defp menu(3, :short, state), do: select(state)
  defp menu(4, :short, state), do: move(state, 1)
  defp menu(_button, _hold, state), do: state

  # **The ends of a level are stops, and the list does not go round.** A knob with
  # detents reads the count of this level, and a detent that ran past the end of the
  # list would turn for ever. See `MyHiFi.Event.Hint.Detents`.
  defp move(%{stack: []} = state, _step), do: state

  defp move(state, step) do
    {above, [current]} = Enum.split(state.stack, -1)
    last = length(current.rows) - 1
    index = (current.index + step) |> Kernel.max(0) |> Kernel.min(Kernel.max(last, 0))

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

    hold_open(state)
  end

  # A menu that is closed already needs no event: the screen draws what plays, and a
  # second `MenuClosed` would make it draw that again.
  defp close(%{stack: []} = state), do: state

  defp close(state) do
    Event.publish(:view, %View.MenuClosed{})
    Event.publish(:hint, %Hint.Detents{count: 0, index: 0})

    let_go(%{state | stack: []})
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

  # **A button that a person holds moves the level, and it reads the level first.** The
  # player keeps no copy of it, and `MyHiFi.Output.Volume` is the one place that does,
  # so a missed event cannot leave this moving from the wrong number.
  #
  # A press that reaches a card with no level does nothing that a person can hear, and
  # the log names the reason. See `MyHiFi.Output.Volume`.
  defp step_volume(step) do
    case Playback.volume!() do
      %{enabled?: true, percent: percent} ->
        report(Playback.set_volume(clamp(percent + step)))

      _other ->
        :ok
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
