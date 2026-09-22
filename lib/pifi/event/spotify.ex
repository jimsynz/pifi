defmodule PiFi.Event.Spotify do
  @moduledoc """
  What a cast is doing, on the `:player` topic.

  **librespot is the only thing that knows.** The capture side of the ALSA loopback
  hands over a full-rate stream of digital silence whether anything is playing or not,
  so nothing downstream can tell a cast from an idle device by looking at the audio. A
  measurement on a board settled that: three seconds of `arecord` with nothing opening
  the playback side gave 529200 bytes and every one of them was zero.

  So `--emit-sink-events` is the handover, and these carry it. They ride the `:player`
  topic because that is what they are about: a cast takes the sound path, and every
  part of this firmware that cares about what is playing already listens there.

  See `PiFi.Spotify.Daemon`.
  """

  defmodule SinkChanged do
    @moduledoc """
    librespot opened or closed its sound path.

    - `:running` — a cast began, and the capture has to start.
    - `:paused` — a person pressed pause in the application. librespot calls this
      `temporarily_closed`, and it means the sink will open again without a new track.
    - `:closed` — the cast is over and the sound path is free.
    """

    @type t :: %__MODULE__{state: :running | :paused | :closed}

    defstruct [:state]
  end

  defmodule TrackChanged do
    @moduledoc """
    A cast moved to another track.

    `track` carries what librespot said about it: the title, the artists as one line,
    the album, the length and the address of the largest cover it named. A telephone
    decides all of it, so nothing here can ask for any of it again.
    """

    @type t :: %__MODULE__{track: map()}

    defstruct [:track]
  end
end
