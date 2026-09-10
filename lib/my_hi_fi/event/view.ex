defmodule MyHiFi.Event.View do
  @moduledoc """
  What a screen draws, on the `:view` topic.

  `MyHiFi.DeviceUi` sends these, and a screen reads them. **The event carries typed
  facts and no pixels**, so a 320 by 240 panel and a 128 by 64 monochrome panel read
  one event and each one decides its own layout. That is the rule that
  `MyHiFi.Peripheral` holds.

  A screen that draws no list ignores the topic, and it needs no line of its own:
  `c:MyHiFi.Peripheral.subscriptions/0` names the topics that a peripheral takes.
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
    long enough that it closes itself. See `MyHiFi.DeviceUi`.
    """

    @type t :: %__MODULE__{}

    defstruct []
  end
end
