defmodule MyHiFi.Event.Input do
  @moduledoc """
  What a person did to the hardware, on the `:input` topic.

  A peripheral sends each of these, and `MyHiFi.DeviceUi` reads them. **A peripheral
  says what happened and not what it means.** A board holds four buttons in a row and
  no label, so the event names the button by its place, and the one module that
  decides what a place does is `MyHiFi.DeviceUi`. A knob that comes later sends its
  own event of this topic in the same way.
  """

  defmodule ButtonPressed do
    @moduledoc """
    A person pressed a button of a peripheral.

    `button` counts from 1, in the order that the buttons sit on the board. The
    PiTFT holds four, and 1 is the one nearest the corner that the ribbon leaves.

    `peripheral` names the module that owns the button, so a device that grows a
    second board of buttons keeps the two apart.

    `hold` says whether a person tapped the button or held it. A board that reads no
    long press gives `:short` for every press. See `MyHiFi.Peripheral.Buttons`.
    """

    @type t :: %__MODULE__{
            peripheral: module(),
            button: pos_integer(),
            hold: :short | :long
          }

    defstruct [:peripheral, :button, hold: :short]
  end
end
