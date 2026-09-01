defmodule MyHiFi.Peripheral.PiTft.ButtonsTest do
  # `MyHiFi.Test.RecordingScreen` is a named process, so two of these cannot run at
  # the same time.
  use ExUnit.Case, async: false

  alias MyHiFi.Peripheral.PiTft.Buttons
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
    {:ok, button, buttons} = Buttons.press(buttons, fell(line, at))
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
      {:ok, 1, buttons} = Buttons.press(buttons, fell(18, 0))

      assert {:none, buttons} = Buttons.press(buttons, rose(18, 5))
      assert {:none, buttons} = Buttons.press(buttons, fell(18, 9))
      assert {:none, buttons} = Buttons.press(buttons, rose(18, 20))
      assert {:none, _buttons} = Buttons.press(buttons, fell(18, 30))
    end

    # The finger leaves the button after longer than the time of the bounce, so the
    # break of the contact is outside that window. A reader of the falling edge alone
    # counted each one as a new press.
    test "the bounce of a release is no press at all", %{buttons: buttons} do
      {:ok, 1, buttons} = Buttons.press(buttons, fell(18, 0))

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
      {:ok, 1, buttons} = Buttons.press(buttons, fell(18, 0))

      assert {:none, _buttons} = Buttons.press(buttons, fell(18, 2000))
    end

    test "the bounce of one button does not quiet another", %{buttons: buttons} do
      {:ok, 1, buttons} = Buttons.press(buttons, fell(18, 0))

      assert {:ok, 2, _buttons} = Buttons.press(buttons, fell(27, 5))
    end
  end

  describe "open/1" do
    test "a line that another part of the system holds gives no button of its own" do
      # `MyHiFi.Test.RecordingScreen` opens every line, so this names one line and
      # proves that the answer holds what it opened and nothing else.
      {:ok, buttons} = Buttons.open(lines: [18])

      assert {:ok, 1, _} = Buttons.press(buttons, fell(18, 0))
      assert {:none, _buttons} = Buttons.press(buttons, fell(27, 0))
    end
  end
end
