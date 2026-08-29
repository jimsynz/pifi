defmodule MyHiFi.Event.Device do
  @moduledoc """
  What the hardware is doing, on the `:device` topic.

  No person changes any of this: a DAC arrives, Wi-Fi connects, and a download fills
  the card. `MyHiFiWeb.SettingsLive` drew these three reports on an interval before,
  and an interval reads the same answer again and again. `MyHiFi.Device.Monitor` owns
  the three sources of truth instead, and it publishes one of these when the answer
  changes.

  Each event carries the whole report, and not a mark that says to read it again.
  `MyHiFi.Playback.output!/0` costs several reads of the settings, and the web page and
  the screen of the device both want the answer, so one process reads it one time.
  """

  defmodule NetworkChanged do
    @moduledoc """
    An interface came up, went down, or took an address.

    `interfaces` is what `MyHiFi.Device.network!/0` gives.
    """

    @type t :: %__MODULE__{interfaces: [map()]}

    defstruct interfaces: []
  end

  defmodule OutputChanged do
    @moduledoc """
    A sound card arrived or went, or a person chose another one.

    The fields are what `MyHiFi.Playback.output!/0` gives. `selected` is the choice of
    a person, and `in_use` is the card that the player plays through. The two are
    different when the chosen card is absent.
    """

    @type t :: %__MODULE__{devices: [map()], selected: String.t() | nil, in_use: String.t() | nil}

    defstruct devices: [], selected: nil, in_use: nil
  end

  defmodule StorageChanged do
    @moduledoc """
    The free space of the writable partition moved.

    The fields are what `MyHiFi.Device.storage!/0` gives. `full?` says that `os_mon`
    raised its alarm for this partition, so a person can be told before a write fails.
    """

    @type t :: %__MODULE__{
            path: String.t(),
            total_bytes: non_neg_integer(),
            free_bytes: non_neg_integer(),
            used_bytes: non_neg_integer(),
            database_bytes: non_neg_integer(),
            full?: boolean()
          }

    defstruct [
      :path,
      :total_bytes,
      :free_bytes,
      :used_bytes,
      :database_bytes,
      full?: false
    ]
  end
end
