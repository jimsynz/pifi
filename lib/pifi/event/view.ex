defmodule PiFi.Event.View do
  @moduledoc """
  What a screen draws, on the `:view` topic.

  `PiFi.DeviceUi` sends these, and a screen reads them. **The event carries typed
  facts and no pixels**, so a 320 by 240 panel and a 128 by 64 monochrome panel read
  one event and each one decides its own layout. That is the rule that
  `PiFi.Peripheral` holds.

  A screen that draws no list ignores the topic, and it needs no line of its own:
  `c:PiFi.Peripheral.subscriptions/0` names the topics that a peripheral takes.
  """

  defmodule MenuShown do
    @moduledoc """
    A person is in the menu, and this is the level that they are on.

    `rows` is the whole level and not the part that fits, because a screen knows how
    many rows fit and this module does not. `index` is the row that a person is on, so
    a screen scrolls its own window around it.

    `depth` counts from 0 at the root. A screen draws a mark for a level that a person
    can leave, and the root is the level that leaves the menu.

    **A row carries a kind and not an icon.** `:open` says that the row leads
    somewhere, `:play` says that it plays, and `:do` says that it acts on the device.
    A screen chooses the mark for each one.
    """

    @typedoc "One row of a level, as a screen reads it."
    @type row :: %{
            title: String.t(),
            subtitle: String.t() | nil,
            kind: :open | :play | :do
          }

    @type t :: %__MODULE__{
            title: String.t(),
            rows: [row()],
            index: non_neg_integer(),
            depth: non_neg_integer()
          }

    defstruct title: "Menu", rows: [], index: 0, depth: 0
  end

  defmodule MenuClosed do
    @moduledoc """
    The menu is gone, and a screen draws what plays.

    A person leaves the root of the menu, a person plays something, or the menu waits
    long enough that it closes itself. See `PiFi.DeviceUi`.
    """

    @type t :: %__MODULE__{}

    defstruct []
  end

  defmodule ScreenBlanked do
    @moduledoc """
    The screen of the device goes dark, or it comes back.

    A screen that stays lit while an episode plays uses the battery for a picture
    that no person reads, so `PiFi.DeviceUi` turns it off after a period of no
    press. **This is not standby.** The audio continues, and the only thing that
    changes is the light.

    **Each screen decides what dark means for it.** The two screens of this firmware
    turn the backlight off and leave the panel awake, so the frame stays in the panel
    and the screen comes back in one frame write. A screen of another kind may do
    something else.

    The event carries `blanked?`, and `false` says that the screen comes back. A press
    of any button brings it back, and that press does nothing else. See
    `PiFi.DeviceUi`.
    """

    @type t :: %__MODULE__{blanked?: boolean()}

    defstruct blanked?: false
  end
end
