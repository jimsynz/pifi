defmodule PiFi.Peripheral.HapticKnobsTest do
  # It reads the level, which one process holds for the whole firmware.
  use PiFi.DataCase, async: false

  alias PiFi.Event
  alias PiFi.Event.Hint
  alias PiFi.Event.Input
  alias PiFi.Peripheral.HapticKnobs
  alias PiFi.Test.FakeKnobBoard

  @left 0
  @right 1

  setup do
    board = start_supervised!({FakeKnobBoard, self()})
    :ok = Event.subscribe(:input)

    %{board: board}
  end

  # A settle of an hour holds every hint back from a knob that turned, and one of 0
  # lets every hint through, so a test never waits on the clock.
  defp start(board, settle_ms \\ :timer.hours(1)) do
    {:ok, state} = HapticKnobs.init(connection: board, settle_ms: settle_ms)
    flush()
    state
  end

  defp flush do
    receive do
      {:knob_set, _index, _settings} -> flush()
    after
      0 -> :ok
    end
  end

  defp report(state, index, position) do
    {:ok, state} = HapticKnobs.handle_info({FocPeripheral, {:position, index, position}}, state)
    state
  end

  defp hint(state, hint) do
    {:ok, state} = HapticKnobs.handle_event(hint, state)
    state
  end

  test "it takes the hints, and no other topic" do
    assert HapticKnobs.subscriptions() == [:hint]
  end

  describe "init/1" do
    # No `PiFi.Output.Volume` runs here, so the level reads as one that nothing sets,
    # and the volume knob has nothing to move.
    test "the left knob turns freely and the right one is limp", %{board: board} do
      {:ok, _state} = HapticKnobs.init(connection: board)

      assert_receive {:knob_set, @left, left}
      assert left[:count] == 0 and left[:detent] == 0.0
      assert_receive {:knob_set, @right, right}
      assert right[:count] == 0 and right[:endstops] == false
    end
  end

  describe "the left knob" do
    test "a level of the menu gives it a detent for each row", %{board: board} do
      board |> start() |> hint(%Hint.Detents{count: 5, index: 2})

      assert_receive {:knob_set, @left, settings}
      assert settings[:count] == 5
      assert settings[:position] == 2
      assert settings[:endstops] == true
    end

    test "a turn says which knob, where it is, and how far it went", %{board: board} do
      board |> start() |> report(@left, 0) |> report(@left, 2)

      assert_receive %Input.KnobTurned{
        peripheral: HapticKnobs,
        knob: 1,
        position: 2,
        step: 2
      }
    end

    test "the first report of a knob is where it is, and not a turn", %{board: board} do
      board |> start() |> report(@left, 3)

      refute_receive %Input.KnobTurned{}, 50
    end

    test "the board's report of a position that this set is not a turn", %{board: board} do
      board
      |> start()
      |> hint(%Hint.Detents{count: 5, index: 2})
      |> report(@left, 2)

      refute_receive %Input.KnobTurned{}, 50
    end

    # The fight that this module exists to avoid: a hint that answers an older turn
    # must not drag the knob back under the hand.
    test "a hint for a knob that is turning leaves it alone", %{board: board} do
      board
      |> start()
      |> hint(%Hint.Detents{count: 5, index: 0})
      |> report(@left, 3)
      |> hint(%Hint.Detents{count: 5, index: 1})

      assert_receive {:knob_set, @left, _settings}
      refute_receive {:knob_set, @left, _settings}, 50
    end

    test "a hint for a knob that is still moves it", %{board: board} do
      board
      |> start(0)
      |> hint(%Hint.Detents{count: 5, index: 0})
      |> report(@left, 3)
      |> hint(%Hint.Detents{count: 5, index: 1})

      assert_receive {:knob_set, @left, _first}
      assert_receive {:knob_set, @left, settings}
      assert settings[:position] == 1
    end

    test "a level with another number of rows reaches a knob that is turning", %{board: board} do
      board
      |> start()
      |> hint(%Hint.Detents{count: 5, index: 0})
      |> report(@left, 3)
      |> hint(%Hint.Detents{count: 9, index: 0})

      assert_receive {:knob_set, @left, _first}
      assert_receive {:knob_set, @left, settings}
      assert settings[:count] == 9
    end
  end

  describe "the right knob" do
    test "while the menu is open it has three positions, from the middle", %{board: board} do
      board |> start() |> hint(%Hint.Stepper{active?: true})

      assert_receive {:knob_set, @right, settings}
      assert settings[:count] == 3
      assert settings[:position] == 1
    end

    test "a step of the stepper is a turn, and the knob goes back to the middle", %{
      board: board
    } do
      board |> start() |> hint(%Hint.Stepper{active?: true}) |> report(@right, 2)

      assert_receive %Input.KnobTurned{knob: 2, step: 1}
      assert_receive {:knob_set, @right, _stepper}
      assert_receive {:knob_set, @right, [position: 1]}
    end

    test "with volume control on, it is the level", %{board: board} do
      board |> start() |> hint(%Hint.Volume{percent: 40, adjustable?: true})

      assert_receive {:knob_set, @right, settings}
      assert settings[:count] == 101
      assert settings[:position] == 40
    end

    # The stepper owns the knob while the menu is open, and the level waits for it to
    # close.
    test "a level that moves while the menu is open waits", %{board: board} do
      board
      |> start()
      |> hint(%Hint.Stepper{active?: true})
      |> hint(%Hint.Volume{percent: 40, adjustable?: true})

      assert_receive {:knob_set, @right, _stepper}
      refute_receive {:knob_set, @right, _volume}, 50
    end
  end

  describe "the board" do
    test "a board that restarts gets every setting again", %{board: board} do
      state = start(board)

      {:ok, _state} = HapticKnobs.handle_info({FocPeripheral, {:hello, 1}}, state)

      assert_receive {:knob_set, @left, _left}
      assert_receive {:knob_set, @right, _right}
    end

    test "a connection that opens sets both knobs", %{board: board} do
      state = start(board)

      {:ok, _state} = HapticKnobs.handle_info({FocPeripheral, :connected}, state)

      assert_receive {:knob_set, @left, _left}
      assert_receive {:knob_set, @right, _right}
    end

    test "a peripheral that stops leaves both knobs limp", %{board: board} do
      board |> start() |> then(&HapticKnobs.terminate(:shutdown, &1))

      assert_receive {:knob_set, @left, left}
      assert left[:detent] == 0.0 and left[:endstops] == false
      assert_receive {:knob_set, @right, right}
      assert right[:detent] == 0.0 and right[:endstops] == false
    end
  end
end
