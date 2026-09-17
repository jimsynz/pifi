defmodule PiFi.Event.Player do
  @moduledoc """
  What the player does, on the `:player` topic.

  `PiFi.Player` sends each of these. A screen and a web page read them, and
  each one ignores a field that it cannot show.
  """

  defmodule Started do
    @moduledoc """
    The player began a track.

    `live?` comes from the playable, and not from the track. A stream with no end,
    such as a radio station, gives `true`. A user interface shows that fact, and
    `duration_ms` cannot say it: a track of a known length holds no duration until
    the first progress event.

    `position_ms` is where the audio began, and it is 0 for a track that began at its
    start. A resume of an episode begins in the middle, and `Progress` arrives one
    second later, so a user interface that held 0 until then would show the wrong time
    for that second.

    `source` names the module, so a user interface reads
    `PiFi.Source.capabilities/0` of it and draws the controls that this track holds.
    """

    @type t :: %__MODULE__{
            source: module(),
            track: PiFi.Source.track(),
            artwork_path: String.t() | nil,
            live?: boolean(),
            position_ms: non_neg_integer()
          }

    defstruct [:source, :track, :artwork_path, live?: false, position_ms: 0]
  end

  defmodule Paused do
    @moduledoc """
    The player stopped the audio, and the track stays selected.

    A pause is not a stop. A stop leaves the device with nothing selected, and a pause
    leaves the track in front of the person, so a user interface keeps the title and it
    draws a play control.

    `position_ms` is where the audio stopped. The player writes that place on to the
    item as well, so a play begins there. See `PiFi.Playback.Item`.
    """

    @type t :: %__MODULE__{position_ms: non_neg_integer()}

    defstruct position_ms: 0
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
    @moduledoc """
    The player could not play, or it stopped with a fault.

    `reason` is what the source or the player gave, so a part that acts on a fault can
    match on it. `message/1` turns it into a sentence. The words live here and not in
    each interface, because the web page and the screen of the device must say the same
    thing about the same fault, and no person reads a tuple.
    """

    @type t :: %__MODULE__{reason: term()}

    defstruct [:reason]

    @doc """
    The fault, in words that a person reads.

    A reason that this does not name gives the reason as it stands. That text is for a
    person who reports a fault, and each one that a person meets earns a sentence here.

        iex> PiFi.Event.Player.Failed.message(:no_output_device)
        "No output is in use. Choose one in the settings."
    """
    @spec message(term()) :: String.t()
    def message({:not_read_yet, title}) do
      "The device holds no address for #{title} yet. It reads the source again by itself."
    end

    def message({:unsupported_format, title}) do
      "This device cannot play the sound format of #{title}."
    end

    def message({:not_a_track, _id}), do: "That entry is not a track, and only a track plays."

    def message({:no_such_show, _ref}), do: "The device holds no show for that entry."

    def message({:cannot_read_playlist, text}) do
      "The device could not read the playlist: #{text}"
    end

    def message({:playlist_status, status}) do
      "The server answered the playlist with the status #{status}."
    end

    def message({:status, status}), do: "The server answered with the status #{status}."

    def message(:no_output_device), do: "No output is in use. Choose one in the settings."

    def message(:not_playing), do: "The track did not answer, so nothing moved."

    def message(reason), do: "The player stopped: #{inspect(reason)}"
  end

  defmodule VolumeChanged do
    @moduledoc """
    The level moved, or a person turned the control on or off.

    `percent` is what a person chose, and it is not a read of the card: a card holds a
    number of steps that no percentage lands on, so a read would fight the control that
    a person is moving. See `PiFi.Output.Volume`.

    `enabled?` says whether this firmware sets the level at all, and `supported?` says
    whether the card in use holds one to set. A person with a DAC of a fixed output
    reads `false` for the second one whatever they chose.
    """

    @type t :: %__MODULE__{
            percent: 0..100,
            enabled?: boolean(),
            supported?: boolean()
          }

    defstruct percent: 100, enabled?: false, supported?: false
  end

  defmodule Standby do
    @moduledoc "The device entered standby, or it left standby."

    @type t :: %__MODULE__{entered?: boolean()}

    defstruct entered?: false
  end
end
