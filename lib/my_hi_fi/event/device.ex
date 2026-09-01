defmodule MyHiFi.Event.Device do
  @moduledoc """
  What the hardware is doing, on the `:device` topic.

  No person changes any of this: a DAC arrives, Wi-Fi connects, a download fills the
  card, and a battery runs down. `MyHiFiWeb.SettingsLive` drew three of these reports on
  an interval before,
  and an interval reads the same answer again and again. `MyHiFi.Device.Monitor` owns
  the three sources of truth instead, and it publishes one of these when the answer
  changes.

  Each event carries the whole report, and not a mark that says to read it again.
  `MyHiFi.Playback.output!/0` costs several reads of the settings, and the web page and
  the screen of the device both want the answer, so one process reads it one time.
  """

  defmodule BatteryChanged do
    @moduledoc """
    The charge of the cell moved.

    `percent` is what the fuel gauge reports, from 0 to 100. `volts` is the voltage of
    the cell, which a person rarely wants and which says what a percentage cannot: a
    gauge that never saw this cell reports a percentage that is wrong until it learns,
    and the voltage is right from the first read.

    `low?` says that the cell reached the point where a person must charge it. **The
    threshold is here and not in each reader**, because three parts answer it: the device
    enters standby, the activity light flashes, and the screen says to charge it. Three
    copies of one number would drift. `MyHiFi.Peripheral.Battery.low_percent/0` holds it,
    and a person sets it.

    **A device on the mains publishes none of these**, because it holds no gauge. A
    reader must therefore draw nothing until one arrives, and never a battery at 0.
    See `MyHiFi.Peripheral.Battery`.
    """

    @type t :: %__MODULE__{percent: 0..100, volts: float(), low?: boolean()}

    defstruct [:percent, :volts, low?: false]
  end

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
