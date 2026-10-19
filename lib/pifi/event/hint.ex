defmodule PiFi.Event.Hint do
  @moduledoc """
  What a control needs to know to move well, on the `:hint` topic.

  A knob with dynamic detents needs the length of the list that a person moves
  through, so that one detent is one row and the end of the list is a stop.
  `PiFi.DeviceUi` owns the list, so it is the one part that can say. It owns the menu
  as well, so it also says when a knob should step back and forward through it.

  **The volume hint comes from `PiFi.Output.Volume`, and not from `PiFi.DeviceUi`.**
  The level changes from the web page, from Home Assistant and from a button, and the
  one process that sees every change is the one that owns the number. `PiFi.DeviceUi`
  would have to take the `:player` topic to see them, and would then wake for each
  progress event to pass on a handful.

  **A knob takes this topic and not the `:player` topic.** `PiFi.Event.Player.Progress`
  arrives once a second while a track plays, and a knob that woke for it would spend
  the board on an event that it cannot use. See `PiFi.Peripheral`.
  """

  defmodule Detents do
    @moduledoc """
    How many stops the control has, and which one a person is on.

    `count` is 0 for a view that a person does not move through, such as the now
    playing view, and a knob then turns with no detent at all.
    """

    @type t :: %__MODULE__{count: non_neg_integer(), index: non_neg_integer()}

    defstruct count: 0, index: 0
  end

  defmodule Stepper do
    @moduledoc """
    Whether a control should step back and forward through the menu.

    `active?` is true while the menu is open. A knob that has no other way to go back
    or to open a row then becomes a switch of three positions: a step one way is back
    and a step the other way is forward.
    """

    @type t :: %__MODULE__{active?: boolean()}

    defstruct active?: false
  end

  defmodule Volume do
    @moduledoc """
    The level, and whether a control can move it.

    `adjustable?` is false while volume control is off, and for a card that has no
    level to set. A volume knob then goes limp, so it says by feel that it is not in
    charge of the level.
    """

    @type t :: %__MODULE__{percent: 0..100, adjustable?: boolean()}

    defstruct percent: 100, adjustable?: false
  end
end
