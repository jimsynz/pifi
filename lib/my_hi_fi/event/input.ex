defmodule MyHiFi.Event.Input do
  @moduledoc """
  What a person did, on the `:input` topic.

  A peripheral sends what a person did to the hardware, and `MyHiFi.DeviceUi` reads
  it. **A peripheral says what happened and not what it means.** A board holds four
  buttons in a row and no label, so the event names the button by its place, and the
  one module that decides what a place does is `MyHiFi.DeviceUi`. A knob that comes
  later sends its own event of this topic in the same way.

  A web page sends what a person did to it, and `MyHiFi.AutoStandby` reads that.
  A person at a browser touched the device as much as a person at the board did.
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

  defmodule PageUsed do
    @moduledoc """
    A person did something on a web page of this device.

    A click, a change of a form, a move to another page, and a load of a page all
    send this. `MyHiFiWeb.Shell` sends it for every LiveView of the firmware, so a
    new page needs no line of its own.

    `page` names the LiveView module that the person used, which tells a reader of
    the log where they were.

    **The event says that a person is there, and nothing more.** A control that
    reaches the player publishes what the player did as well, on the `:player`
    topic, and a reader that wants to know what changed reads that one.
    """

    @type t :: %__MODULE__{page: module()}

    defstruct [:page]
  end
end
