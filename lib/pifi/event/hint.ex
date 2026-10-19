defmodule PiFi.Event.Hint do
  @moduledoc """
  What a control needs to know to move well, on the `:hint` topic.

  A knob with dynamic detents needs the length of the list that a person moves
  through, so that one detent is one row and the end of the list is a stop.
  `PiFi.DeviceUi` owns the list, so it is the one part that can say. It owns the menu
  as well, so it also says when a knob should step back and forward through it.

  **The scrub hint comes from `PiFi.Player`**, for the same reason as the volume hint
  below: it is the one part that knows whether the track that plays can move.

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

  defmodule Menu do
    @moduledoc """
    Whether the menu is open.

    A control can do one thing while the menu is open and another while it is closed:
    a knob that sets the level with the menu closed can step back and forward through
    it once it opens. `PiFi.Event.Hint.Detents` says how many rows the open level has,
    and this says whether there is a level at all, which a count cannot: a level with
    no rows is still open, and a person still needs a way back out of it.
    """

    @type t :: %__MODULE__{open?: boolean()}

    defstruct open?: false
  end

  defmodule Scrub do
    @moduledoc """
    Whether the track that plays can be skipped within.

    `PiFi.Player` publishes this, because it is the one part that knows: a live stream,
    a cast and a paused track take no skip, and nor does a format whose frames this
    firmware cannot read. A jog wheel goes limp when it is false, so it says by feel
    that there is nothing to move through.
    """

    @type t :: %__MODULE__{available?: boolean()}

    defstruct available?: false
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
