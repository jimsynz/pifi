defmodule MyHiFi.Event.Player do
  @moduledoc """
  What the player does, on the `:player` topic.

  `MyHiFi.Player` sends each of these. A screen and a web page read them, and
  each one ignores a field that it cannot show.
  """

  defmodule Started do
    @moduledoc """
    The player began a track.

    `live?` comes from the playable, and not from the track. A stream with no end,
    such as a radio station, gives `true`. A user interface shows that fact, and
    `duration_ms` cannot say it: a track of a known length holds no duration until
    the first progress event.
    """

    @type t :: %__MODULE__{
            source: module(),
            track: MyHiFi.Source.track(),
            artwork_path: String.t() | nil,
            live?: boolean()
          }

    defstruct [:source, :track, :artwork_path, live?: false]
  end

  defmodule Stopped do
    @moduledoc "The player stopped. `reason` is `:requested` when a person asked."

    @type t :: %__MODULE__{reason: atom() | term()}

    defstruct [:reason]
  end

  defmodule Buffering do
    @moduledoc """
    The player is filling its buffer and has no sound yet.

    `percent` counts from 0 to 100.
    """

    @type t :: %__MODULE__{percent: 0..100}

    defstruct percent: 0
  end

  defmodule Progress do
    @moduledoc """
    How far the track has played.

    `duration_ms` is `nil` for a live stream, so a screen shows the time from the
    start and no bar.
    """

    @type t :: %__MODULE__{position_ms: non_neg_integer(), duration_ms: pos_integer() | nil}

    defstruct position_ms: 0, duration_ms: nil
  end

  defmodule MetadataChanged do
    @moduledoc """
    The stream named a new track.

    A Shoutcast stream sends this in the ICY blocks between the audio.
    """

    @type t :: %__MODULE__{
            title: String.t() | nil,
            artist: String.t() | nil,
            artwork_path: String.t() | nil
          }

    defstruct [:title, :artist, :artwork_path]
  end

  defmodule Failed do
    @moduledoc "The player could not play, or it stopped with a fault."

    @type t :: %__MODULE__{reason: term()}

    defstruct [:reason]
  end

  defmodule Standby do
    @moduledoc "The device entered standby, or it left standby."

    @type t :: %__MODULE__{entered?: boolean()}

    defstruct entered?: false
  end
end
