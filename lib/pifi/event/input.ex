defmodule PiFi.Event.Input do
  @moduledoc """
  What a person did, on the `:input` topic.

  A peripheral sends what a person did to the hardware, and `PiFi.DeviceUi` reads
  it. Each event names the job that a person gave the control on the settings page,
  and `PiFi.DeviceUi` is the one module that decides what a job does to the device.

  A web page sends what a person did to it, and `PiFi.AutoStandby` reads that.
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
    long press gives `:short` for every press. See `PiFi.Peripheral.Buttons`.

    `function` is the job a person gave this press with the menu closed, and
    `menu_function` the one with it open. `PiFi.DeviceUi` picks between them, because
    it knows for certain whether the menu is open. See `PiFi.Peripheral.ButtonJobs`,
    which builds this event and lists the jobs.
    """

    @type t :: %__MODULE__{
            peripheral: module(),
            button: pos_integer(),
            hold: :short | :long,
            function: PiFi.Peripheral.ButtonJobs.job(),
            menu_function: PiFi.Peripheral.ButtonJobs.job()
          }

    defstruct [:peripheral, :button, hold: :short, function: :none, menu_function: :none]
  end

  defmodule KnobTurned do
    @moduledoc """
    A person turned a knob of a peripheral to another position.

    `knob` counts from 1, in the order that the knobs sit on the board, left to right.
    `position` is the position that the knob is on now, and `step` is how far it moved
    to get there, so a control that sets a value reads the first and a control that
    goes back and forward reads the second.

    `velocity` is how fast it was turning, in radians a second, so a jog wheel can
    move further for a faster turn.

    `peripheral` names the module that owns the knob, in the way that
    `PiFi.Event.Input.ButtonPressed` names the board of a button.

    **A knob names one job, and a button names two.** A knob's feel has to match its
    job: a knob of rows has a detent for each row and a jog wheel has none. So the
    peripheral reads the menu hint and the settings, and `function` names what the
    knob does now, with the menu open or closed as it is. `PiFi.DeviceUi` still
    decides what each job does to the device.

    - `:open_menu` - open the menu
    - `:rows` - `position` is the row of the open level
    - `:back_forward` - a step left is back, a step right opens or plays the row
    - `:volume` - `position` is the level
    - `:jog` - each step moves within the track that plays
    - `:none` - nothing, though the turn still says a person is there
    """

    @type function_name :: :open_menu | :rows | :back_forward | :volume | :jog | :none

    @type t :: %__MODULE__{
            peripheral: module(),
            knob: pos_integer(),
            function: function_name(),
            position: integer(),
            step: integer(),
            velocity: float()
          }

    defstruct [:peripheral, :knob, :function, :position, :step, velocity: 0.0]
  end

  defmodule PageUsed do
    @moduledoc """
    A person did something on a web page of this device.

    A click, a change of a form, a move to another page, and a load of a page all
    send this. `PiFiWeb.Shell` sends it for every LiveView of the firmware, so a
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
