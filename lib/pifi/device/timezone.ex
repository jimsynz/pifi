defmodule PiFi.Device.Timezone do
  @moduledoc """
  What time it is where the device is.

  **Everything this firmware stores is UTC, and that does not change.** A row carries
  the moment it happened and nothing else, so a person who moves the device across a
  border reads their history in the new place without a single row being rewritten.
  This is the one place that turns those moments into the time on the wall.

  ## Why a device needs to be told

  A stereo has no way to work it out. There is no browser to ask, `nerves_time` brings
  the clock from NTP in UTC, and an IP address is a guess that is wrong on a VPN. So a
  person says, once.

  A device that no person told is on `Etc/UTC`, which is honest: it shows the time it
  knows rather than a time it guessed.

  ## What it is for

  **Scheduling, first.** `PiFi.Application.oban_config/0` gives the cron plugin this
  zone, so `17 4 * * *` is seventeen minutes past four in the morning where the person
  sleeps rather than wherever UTC happens to fall for them. A device in New Zealand
  checked for a firmware at four in the afternoon before this existed.

  **Reading, second.** Every time that a page draws goes through `at/1`, so a history
  reads in local time.

  ## Why a name and not an offset

  An offset is wrong twice a year. `Pacific/Auckland` is +12 in winter and +13 in
  summer, and a person who set +12 would find their overnight job running an hour late
  for half the year. The name carries the rule, and `tz` carries the names.

  ## It validates by asking, and it holds no list

  `tz` compiles the IANA database into modules and exposes no list of what it holds, so
  there is nothing here to check a name against and nothing to go stale. `DateTime.now/1`
  answers `{:error, :time_zone_not_found}` for a name that the database does not carry,
  which is the same question asked of the thing that will have to answer it later.

  `common/0` is a short list for a person to pick from and not the set of what is
  allowed: a person whose zone is not on it types the name.
  """

  alias PiFi.Settings

  @key "device.timezone"
  @default "Etc/UTC"

  # A list to pick from, and not a list of what is allowed. It covers the places this
  # product is likely to sit, and `put/1` takes any name that the database carries.
  @common [
    "Etc/UTC",
    "Pacific/Auckland",
    "Pacific/Chatham",
    "Australia/Sydney",
    "Australia/Brisbane",
    "Australia/Adelaide",
    "Australia/Perth",
    "Asia/Singapore",
    "Asia/Tokyo",
    "Asia/Kolkata",
    "Asia/Dubai",
    "Europe/London",
    "Europe/Dublin",
    "Europe/Lisbon",
    "Europe/Paris",
    "Europe/Berlin",
    "Europe/Madrid",
    "Europe/Rome",
    "Europe/Amsterdam",
    "Europe/Stockholm",
    "Europe/Helsinki",
    "Europe/Athens",
    "Europe/Warsaw",
    "Africa/Johannesburg",
    "Africa/Lagos",
    "Africa/Nairobi",
    "America/Sao_Paulo",
    "America/Argentina/Buenos_Aires",
    "America/Santiago",
    "America/Mexico_City",
    "America/New_York",
    "America/Toronto",
    "America/Chicago",
    "America/Denver",
    "America/Phoenix",
    "America/Los_Angeles",
    "America/Vancouver",
    "America/Anchorage",
    "Pacific/Honolulu",
    "Pacific/Fiji"
  ]

  @doc """
  The settings key that holds the zone.

      iex> PiFi.Device.Timezone.key()
      "device.timezone"
  """
  @spec key() :: String.t()
  def key, do: @key

  @doc """
  The zone of a device that no person told.

      iex> PiFi.Device.Timezone.default()
      "Etc/UTC"
  """
  @spec default() :: String.t()
  def default, do: @default

  @doc """
  Names for a person to pick from.

  It is a convenience and not a rule. See the module documentation.

      iex> "Pacific/Auckland" in PiFi.Device.Timezone.common()
      true
  """
  @spec common() :: [String.t()]
  def common, do: @common

  @doc """
  The zone that this device is in.

  **A name that the database no longer carries reads as the default.** IANA removes one
  now and then, and a device that kept an unknown name would raise in every page that
  draws a time.
  """
  @spec get() :: String.t()
  def get do
    with {:ok, %{value: value}} <- Settings.fetch(@key),
         true <- known?(value) do
      value
    else
      _other -> @default
    end
  end

  @doc """
  Say where this device is.

  It answers `{:error, :time_zone_not_found}` for a name that the database does not
  carry, so a person who mistypes one is told rather than left with a device that reads
  the wrong hour.
  """
  @spec put(String.t()) :: :ok | {:error, :time_zone_not_found}
  def put(zone) when is_binary(zone) do
    if known?(zone) do
      Settings.put!(@key, zone)

      :ok
    else
      {:error, :time_zone_not_found}
    end
  end

  @doc """
  Whether the database carries this name.

      iex> PiFi.Device.Timezone.known?("Pacific/Auckland")
      true

      iex> PiFi.Device.Timezone.known?("Middle/Earth")
      false
  """
  @spec known?(String.t()) :: boolean()
  def known?(zone) when is_binary(zone), do: match?({:ok, _now}, DateTime.now(zone))
  def known?(_zone), do: false

  @doc """
  One moment, on the clock of this device.

  Every page that draws a time goes through this. A moment that cannot be shifted — a
  zone that went while a page was open, or a gap in the rules — reads as it was stored,
  because an hour that is out by one is better than a page that will not draw.
  """
  @spec at(DateTime.t()) :: DateTime.t()
  def at(%DateTime{} = moment) do
    case DateTime.shift_zone(moment, get()) do
      {:ok, shifted} -> shifted
      {:error, _reason} -> moment
    end
  end

  @doc "The time on this device now."
  @spec now() :: DateTime.t()
  def now, do: at(DateTime.utc_now())

  @doc """
  What to write after a time that this device drew.

  A device that a person never told says `UTC`, so they can see that it is showing the
  time it knows rather than the time where they are. One that they did told needs no
  such warning: the hour is already theirs.

      iex> PiFi.Device.Timezone.suffix("Etc/UTC")
      " UTC"

      iex> PiFi.Device.Timezone.suffix("Pacific/Auckland")
      ""
  """
  @spec suffix(String.t()) :: String.t()
  def suffix(@default), do: " UTC"
  def suffix(_zone), do: ""
end
