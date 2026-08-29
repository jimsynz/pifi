defmodule MyHiFi.Event.Source do
  @moduledoc """
  What a source says about its own content, on the `:source` topic.

  A source reads a service behind the page, so what one container holds can change
  while a person looks at it. The source sends this, and a user interface that shows
  that container reads it again.

  The event carries no entry. A web page and a device screen show different fields of
  one, and each one already knows how to read a container. See `MyHiFi.Source.browse/2`.
  """

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
