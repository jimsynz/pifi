defmodule MyHiFi.Peripheral.ButtonsTest do
  # `MyHiFi.Test.RecordingScreen` is a named process, so two of these cannot run at
  # the same time.
  use ExUnit.Case, async: false

  alias MyHiFi.Peripheral.Buttons
  alias MyHiFi.Test.RecordingScreen

  @a_millisecond 1_000_000

  setup do
    RecordingScreen.use_it()
    {:ok, buttons} = Buttons.open()

    %{buttons: buttons}
  end

  defp fell(line, at), do: {:circuits_gpio, line, at * @a_millisecond, 0}
  defp rose(line, at), do: {:circuits_gpio, line, at * @a_millisecond, 1}

  # A press and the release that arms the next one.
  defp pressed(buttons, line, at) do
    {:ok, button, :short, buttons} = Buttons.press(buttons, fell(line, at))
    {:none, buttons} = Buttons.press(buttons, rose(line, at + 100))

    {button, buttons}
  end

  describe "press/2" do
    test "each line is the button that sits in that place", %{buttons: buttons} do
      # The row reads: standby, the track before, play or pause, the track after. See
      # `MyHiFi.DeviceUi`.
      assert {1, buttons} = pressed(buttons, 18, 0)
      assert {2, buttons} = pressed(buttons, 27, 200)
      assert {3, buttons} = pressed(buttons, 22, 400)
      assert {4, _buttons} = pressed(buttons, 23, 600)
    end

    test "a finger that leaves the button is not a press", %{buttons: buttons} do
      assert {:none, _buttons} = Buttons.press(buttons, rose(18, 0))
    end

    test "a line that no button holds gives nothing", %{buttons: buttons} do
      assert {:none, _buttons} = Buttons.press(buttons, fell(4, 0))
    end

    test "a message of something else gives nothing", %{buttons: buttons} do
      assert {:none, _buttons} = Buttons.press(buttons, {:tcp_closed, make_ref()})
    end

    # A press of one of these gave six changes of level on the board.
    test "the bounce of a press is one press", %{buttons: buttons} do
      {:ok, 1, :short, buttons} = Buttons.press(buttons, fell(18, 0))

      assert {:none, buttons} = Buttons.press(buttons, rose(18, 5))
      assert {:none, buttons} = Buttons.press(buttons, fell(18, 9))
      assert {:none, buttons} = Buttons.press(buttons, rose(18, 20))
      assert {:none, _buttons} = Buttons.press(buttons, fell(18, 30))
    end

    # The finger leaves the button after longer than the time of the bounce, so the
    # break of the contact is outside that window. A reader of the falling edge alone
    # counted each one as a new press.
    test "the bounce of a release is no press at all", %{buttons: buttons} do
      {:ok, 1, :short, buttons} = Buttons.press(buttons, fell(18, 0))

      # The finger leaves at 300 ms, and the contact then breaks and makes again.
      {:none, buttons} = Buttons.press(buttons, rose(18, 300))

      assert {:none, buttons} = Buttons.press(buttons, fell(18, 305))
      assert {:none, buttons} = Buttons.press(buttons, rose(18, 312))
      assert {:none, _buttons} = Buttons.press(buttons, fell(18, 320))
    end

    test "a person who presses again is two presses", %{buttons: buttons} do
      {1, buttons} = pressed(buttons, 18, 0)

      assert {1, _buttons} = pressed(buttons, 18, 300)
    end

    test "a button that is held down gives one press", %{buttons: buttons} do
      {:ok, 1, :short, buttons} = Buttons.press(buttons, fell(18, 0))

      assert {:none, _buttons} = Buttons.press(buttons, fell(18, 2000))
    end

    test "the bounce of one button does not quiet another", %{buttons: buttons} do
      {:ok, 1, :short, buttons} = Buttons.press(buttons, fell(18, 0))

      assert {:ok, 2, :short, _buttons} = Buttons.press(buttons, fell(27, 5))
    end
  end

  describe "open/1" do
    test "a line that another part of the system holds gives no button of its own" do
      # `MyHiFi.Test.RecordingScreen` opens every line, so this names one line and
      # proves that the answer holds what it opened and nothing else.
      {:ok, buttons} = Buttons.open(lines: [18])

      assert {:ok, 1, :short, _} = Buttons.press(buttons, fell(18, 0))
      assert {:none, _buttons} = Buttons.press(buttons, fell(27, 0))
    end
  end

  # A board that names `hold_ms` reads a tap and a hold apart, so it answers at the
  # release and not at the press. See `MyHiFi.Peripheral.Buttons`.
  describe "a board that reads a long press" do
    setup do
      RecordingScreen.use_it()
      {:ok, buttons} = Buttons.open(lines: [5, 6], hold_ms: 50)

      %{held: buttons}
    end

    test "a press alone answers nothing, because it says nothing yet", %{held: buttons} do
      assert {:none, _buttons} = Buttons.press(buttons, fell(5, 0))
    end

    test "a tap answers short at the release", %{held: buttons} do
      {:none, buttons} = Buttons.press(buttons, fell(5, 0))

      assert {:ok, 1, :short, _buttons} = Buttons.press(buttons, rose(5, 100))
    end

    test "a hold answers long when the period passes, and not at the release" do
      RecordingScreen.use_it()
      {:ok, buttons} = Buttons.open(lines: [5], hold_ms: 10)

      {:none, buttons} = Buttons.press(buttons, fell(5, 0))

      assert_receive {Buttons, :held, 5, ref}, 500
      assert {:ok, 1, :long, buttons} = Buttons.press(buttons, {Buttons, :held, 5, ref})

      # The release of a hold that answered already answers no second time.
      assert {:none, _buttons} = Buttons.press(buttons, rose(5, 1000))
    end

    # The timer is not cancelled at a release, so a message that arrives after one must
    # match no press at all.
    test "the timer of a tap answers nothing after the release" do
      RecordingScreen.use_it()
      {:ok, buttons} = Buttons.open(lines: [5], hold_ms: 10)

      {:none, buttons} = Buttons.press(buttons, fell(5, 0))
      assert_receive {Buttons, :held, 5, ref}, 500
      {:ok, 1, :short, buttons} = Buttons.press(buttons, rose(5, 100))

      assert {:none, _buttons} = Buttons.press(buttons, {Buttons, :held, 5, ref})
    end

    test "a second button is the second button, and it holds too", %{held: buttons} do
      {:none, buttons} = Buttons.press(buttons, fell(6, 0))

      assert {:ok, 2, :short, _buttons} = Buttons.press(buttons, rose(6, 100))
    end
  end
end
