defmodule MyHiFi.Peripheral.PiTft.Buttons do
  @moduledoc """
  The four buttons of the PiTFT, on GPIO lines of the Raspberry Pi.

  Each button joins its line to ground, and this opens the line with the pull up of
  the chip, so a line reads 1 while nothing presses it and 0 while a finger does.

  The lines are 18, 27, 22 and 23, in the order that the buttons sit. **Read that
  order one button at a time**: a person who presses four buttons in one go gives a
  list of events that holds no place, and two builds of this firmware named the wrong
  order from such a list. A person pressed each button alone, and
  `MyHiFi.Event.Input.ButtonPressed` named the line each time. **Line 18 is a button
  and not the backlight.**
  The Adafruit PiTFT joins that line to the light through a solder jumper, and the
  clone that this firmware drives holds no such jumper, so an earlier version of this
  firmware held the line for a light that it could not turn off and the fourth button
  could not be read. See `MyHiFi.Peripheral.PiTft.Stmpe610`.

  ## The bounce

  A press of one of these gave six changes of level in a measurement, and each one
  would be a press to a reader that counted them.

  **This module holds the level of each line, and it reads both edges to keep it.** A
  press is a change to 0 of a line that this module holds as up, and the line then
  stays down until a change to 1 that lasts. A change that arrives inside 50 ms of the
  last one that counted is bounce, and it changes nothing.

  A first version watched the change to 0 alone, and it counted the bounce of the
  release as more presses: the finger leaves the button after longer than 50 ms, the
  contact then breaks and makes again, and each break looked like a new press.

  The release is not an event of this firmware. A button of a stereo does its work
  when a person presses it, and the release is here to arm the next press.
  """

  alias Circuits.GPIO

  require Logger

  # In the order that the buttons sit on the board, so the first one is button 1.
  @lines [18, 27, 22, 23]

  @debounce_ms 50

  @typedoc "The open lines, and the level that each one settled at."
  @type t :: %__MODULE__{
          handles: %{pos_integer() => GPIO.Handle.t()},
          buttons: %{pos_integer() => pos_integer()},
          levels: %{pos_integer() => {:up | :down, integer()}}
        }

  defstruct handles: %{}, buttons: %{}, levels: %{}

  @doc """
  Take hold of the lines of the buttons.

  ## Options

  - `:lines` - the GPIO lines, in the order that the buttons sit. `#{inspect(@lines)}`
    by default.

  A line that another part of the system holds gives no button, and the rest still
  work. The log then names it, because a board that gives no button at all is a fault
  that a person needs to see, and one that gives three is worth reading about.
  """
  @spec open(keyword()) :: {:ok, t()}
  def open(opts \\ []) do
    lines = Keyword.get(opts, :lines, @lines)

    {:ok, Enum.reduce(Enum.with_index(lines, 1), %__MODULE__{}, &take_line/2)}
  end

  @doc """
  Which button a message of `Circuits.GPIO` names, if it is a press.

  It gives `{:ok, button, buttons}` for a press and `{:none, buttons}` for anything
  else: a release, a bounce, and a message that belongs to something other than these
  lines. **Both answers hold the buttons again**, because a release arms the next
  press, so a caller that kept the answer of a press alone would take one press and
  no more.
  """
  @spec press(t(), term()) :: {:ok, pos_integer(), t()} | {:none, t()}
  def press(buttons, {:circuits_gpio, line, timestamp, value}) do
    case Map.fetch(buttons.buttons, line(line)) do
      {:ok, button} -> changed(buttons, line(line), button, value, timestamp)
      :error -> {:none, buttons}
    end
  end

  def press(buttons, _message), do: {:none, buttons}

  @doc "Give the lines back."
  @spec close(t()) :: :ok
  def close(buttons) do
    Enum.each(buttons.handles, fn {_line, handle} -> GPIO.close(handle) end)
  end

  defp take_line({line, button}, buttons) do
    case GPIO.open(line, :input, pull_mode: :pullup) do
      {:ok, handle} ->
        GPIO.set_interrupts(handle, :both)

        %{
          buttons
          | handles: Map.put(buttons.handles, line, handle),
            buttons: Map.put(buttons.buttons, line, button)
        }

      {:error, reason} ->
        Logger.warning("Button #{button} on GPIO #{line} is not available: #{inspect(reason)}")

        buttons
    end
  end

  # `Circuits.GPIO` names the line of a message by the same spec that opened it, and a
  # line of this board is a number.
  defp line({_chip, line}), do: line
  defp line(line), do: line

  # A line holds the pull up of the chip, so 0 is a finger on the button and 1 is the
  # button at rest.
  defp changed(buttons, line, button, 0, timestamp) do
    if settled?(buttons, line, :up, timestamp) do
      {:ok, button, note(buttons, line, :down, timestamp)}
    else
      {:none, buttons}
    end
  end

  defp changed(buttons, line, _button, 1, timestamp) do
    if settled?(buttons, line, :down, timestamp) do
      {:none, note(buttons, line, :up, timestamp)}
    else
      {:none, buttons}
    end
  end

  # A change counts when the line holds the other level and the level before it
  # lasted. The timestamp of `Circuits.GPIO` is in nanoseconds, from the same clock
  # for each message. A line that this has not seen yet is up, because nothing holds
  # the button down.
  defp settled?(buttons, line, level, timestamp) do
    case Map.fetch(buttons.levels, line) do
      {:ok, {^level, was}} -> timestamp - was >= @debounce_ms * 1_000_000
      {:ok, {_other, _was}} -> false
      :error -> level == :up
    end
  end

  defp note(buttons, line, level, timestamp) do
    %{buttons | levels: Map.put(buttons.levels, line, {level, timestamp})}
  end
end
