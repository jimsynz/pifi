defmodule MyHiFi.Event.Source do
  @moduledoc """
  What a source says about its own content, on the `:source` topic.

  A source reads a service behind the page, so what one container holds can change
  while a person looks at it. The source sends this, and a user interface that shows
  that container reads it again.

  The event carries no entry. A web page and a device screen show different fields of
  one, and each one already knows how to read a container. See `MyHiFi.Source.browse/2`.
  """

  defmodule AudioChanged do
    @moduledoc """
    What this device holds of the audio of one item moved.

    A person reads whether a track plays with no network, and a row of a list draws
    that. `MyHiFi.Player.Download` sends this while it reads a file and once when the
    file is whole.

    **No source sends this one, and it rides this topic on purpose.** What the card
    holds of an item is a fact about the content and not about the player, and every
    part that draws a list already takes the `:source` topic: `MyHiFiWeb.ItemList`
    subscribes to it for `Changed`, so a page needs no new subscription and no page
    changed to draw this.

    `bytes` is what the card holds now, and a reader that knows `byte_size` of the
    item makes a share of it. The event carries no share of its own, because the item
    holds that number already.

    **It arrives at most once a second while a file reads.** The download writes about
    one message for each 16 KB, which is 2500 of them for a track of 40 MB, and a page
    that drew itself again for each one would spend the board on a number that moves
    too fast to read. `MyHiFi.Event.Player.Progress` holds the same period for the same
    reason.
    """

    @type t :: %__MODULE__{
            item_id: Ash.UUID.t(),
            state: :reading | :held | :absent,
            bytes: non_neg_integer()
          }

    defstruct [:item_id, :state, bytes: 0]
  end

  defmodule Changed do
    @moduledoc """
    The entries inside one container changed.

    `source` names the module and `ref` is a term of that source. A reader compares
    both, because two sources can hold the same `ref`.
    """

    @type t :: %__MODULE__{source: module(), ref: MyHiFi.Source.ref()}

    defstruct [:source, :ref]
  end
end
