defmodule PiFi.Event.Hint do
  @moduledoc """
  What a control needs to know to move well, on the `:hint` topic.

  A knob with dynamic detents needs the length of the list that a person moves
  through, so that one detent is one row and the end of the list is a stop.
  `PiFi.DeviceUi` owns the list, so it is the one part that can say.

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
end
