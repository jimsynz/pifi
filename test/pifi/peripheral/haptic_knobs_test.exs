defmodule PiFi.Peripheral.HapticKnobsTest do
  # It reads the level and the settings, which one process each holds for the firmware.
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

    on_exit(fn ->
      for %{key: key} <- HapticKnobs.settings() do
        case PiFi.Settings.fetch("peripheral.haptic-knobs." <> key) do
          {:ok, setting} -> PiFi.Settings.delete!(setting)
          {:error, _reason} -> :ok
        end
      end
    end)

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

  defp report(state, index, position, velocity \\ 0.0) do
    {:ok, state} =
      HapticKnobs.handle_info({FocPeripheral, {:position, index, position, velocity}}, state)

    state
  end

  defp hint(state, hint) do
    {:ok, state} = HapticKnobs.handle_event(hint, state)
    state
  end

  defp open_menu(state, count \\ 5) do
    state |> hint(%Hint.Detents{count: count, index: 0}) |> hint(%Hint.Menu{open?: true})
  end

  test "it takes the hints, and no other topic" do
    assert HapticKnobs.subscriptions() == [:hint]
  end

  describe "with the jobs a new device starts with" do
    # No `PiFi.Output.Volume` runs here, so the level reads as one that nothing sets, and
    # no track plays, so there is nothing to jog through either.
    test "the left knob opens the menu and the right one is limp", %{board: board} do
      {:ok, _state} = HapticKnobs.init(connection: board)

      assert_receive {:knob_set, @left, left}
      assert left[:count] == 0 and left[:click] == 1.0
      assert_receive {:knob_set, @right, right}
      assert right[:detent] == 0.0 and right[:endstops] == false and right[:click] == 0.0
    end

    test "an open menu gives the left knob a detent for each row", %{board: board} do
      board |> start() |> open_menu(5)

      assert_receive {:knob_set, @left, settings}
      assert settings[:count] == 5
      assert settings[:endstops] == true
    end

    test "an open menu makes the right knob back and forward, from the middle", %{
      board: board
    } do
      board |> start() |> open_menu()

      assert_receive {:knob_set, @right, settings}
      assert settings[:count] == 3
      assert settings[:position] == 1
    end

    test "with volume control on, the right knob is the level", %{board: board} do
      board |> start() |> hint(%Hint.Volume{percent: 40, adjustable?: true})

      assert_receive {:knob_set, @right, settings}
      assert settings[:count] == 101
      assert settings[:position] == 40
    end

    test "with volume control off and a track to move through, it jogs", %{board: board} do
      board |> start() |> hint(%Hint.Scrub{available?: true})

      assert_receive {:knob_set, @right, settings}
      assert settings[:endstops] == false and settings[:detent] > 0
    end
  end

  describe "a turn" do
    test "says which knob, what it does, where it is, and how fast", %{board: board} do
      board |> start() |> report(@left, 0) |> report(@left, 2, 3.5)

      assert_receive %Input.KnobTurned{
        peripheral: HapticKnobs,
        knob: 1,
        function: :open_menu,
        position: 2,
        step: 2,
        velocity: 3.5
      }
    end

    test "the first report of a knob is where it is, and not a turn", %{board: board} do
      board |> start() |> report(@left, 3)

      refute_receive %Input.KnobTurned{}, 50
    end

    test "the board's report of a position that this set is not a turn", %{board: board} do
      board |> start() |> open_menu() |> report(@left, 0)

      refute_receive %Input.KnobTurned{}, 50
    end

    test "a step of back and forward sends the knob back to the middle", %{board: board} do
      board |> start() |> open_menu() |> report(@right, 2)

      assert_receive %Input.KnobTurned{knob: 2, function: :back_forward, step: 1}
      assert_receive {:knob_set, @right, [position: 1]}
    end
  end

  # The fight that this module exists to avoid: a hint that answers an older turn must
  # not drag the knob back under the hand.
  describe "a knob that is turning" do
    test "keeps its own row", %{board: board} do
      board
      |> start()
      |> open_menu(5)
      |> report(@left, 3)
      |> hint(%Hint.Detents{count: 5, index: 1})

      assert_receive {:knob_set, @left, _opened}
      refute_receive {:knob_set, @left, _settings}, 50
    end

    test "takes the row once it is still", %{board: board} do
      board
      |> start(0)
      |> open_menu(5)
      |> report(@left, 3)
      |> hint(%Hint.Detents{count: 5, index: 1})

      assert_receive {:knob_set, @left, _opened}
      assert_receive {:knob_set, @left, settings}
      assert settings[:position] == 1
    end

    test "takes a level with another number of rows at once", %{board: board} do
      board
      |> start()
      |> open_menu(5)
      |> report(@left, 3)
      |> hint(%Hint.Detents{count: 9, index: 0})

      assert_receive {:knob_set, @left, _opened}
      assert_receive {:knob_set, @left, settings}
      assert settings[:count] == 9
    end
  end

  describe "the settings" do
    test "each job is a choice, and the board has two knobs to start with" do
      assert [%{key: "knobs", type: :select, value: "2"} | jobs] = HapticKnobs.settings()
      assert Enum.map(jobs, & &1.key) == ~w(left_closed left_open right_closed right_open)
    end

    test "a save keeps the jobs, and a knob starts with them", %{board: board} do
      assert {:ok, _message} = HapticKnobs.put_settings(%{"right_closed" => "jog"})

      board |> start() |> hint(%Hint.Scrub{available?: true})

      assert_receive {:knob_set, @right, settings}
      assert settings[:detent] > 0 and settings[:endstops] == false
    end

    test "a value that isn't a choice is refused, and nothing is kept" do
      assert {:error, _message} =
               HapticKnobs.put_settings(%{"left_closed" => "volume", "knobs" => "7"})

      assert %{value: "open_menu"} = Enum.find(HapticKnobs.settings(), &(&1.key == "left_closed"))
    end

    test "a board with one knob leaves the second limp, and reads nothing from it", %{
      board: board
    } do
      {:ok, _message} = HapticKnobs.put_settings(%{"knobs" => "1"})
      {:ok, state} = HapticKnobs.init(connection: board)

      assert_receive {:knob_set, @left, _left}
      assert_receive {:knob_set, @right, right}
      assert right[:detent] == 0.0

      state |> report(@right, 0) |> report(@right, 4)
      refute_receive %Input.KnobTurned{}, 50
    end
  end

  describe "the board" do
    test "a board that restarts gets every setting again", %{board: board} do
      state = start(board)

      {:ok, _state} = HapticKnobs.handle_info({FocPeripheral, {:hello, 2, "0.2.0"}}, state)

      assert_receive {:knob_set, @left, _left}
      assert_receive {:knob_set, @right, _right}
    end

    test "a connection that opens sets every knob", %{board: board} do
      state = start(board)

      {:ok, _state} = HapticKnobs.handle_info({FocPeripheral, :connected}, state)

      assert_receive {:knob_set, @left, _left}
      assert_receive {:knob_set, @right, _right}
    end

    test "a peripheral that stops leaves every knob limp", %{board: board} do
      board |> start() |> then(&HapticKnobs.terminate(:shutdown, &1))

      assert_receive {:knob_set, @left, left}
      assert left[:detent] == 0.0 and left[:endstops] == false
      assert_receive {:knob_set, @right, right}
      assert right[:detent] == 0.0 and right[:endstops] == false
    end
  end
end
