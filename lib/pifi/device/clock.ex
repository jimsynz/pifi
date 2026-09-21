defmodule PiFi.Device.Clock do
  @moduledoc """
  What time this device thinks it is, and where it thinks it is.

  `PiFi.Device.Timezone` holds the decision and the reasons. This is the way a page or
  an API reaches it, in the way that `PiFi.Device.Network` is the way a page reaches the
  interfaces: a generic action rather than a plain function, so an extension can serve
  it and a policy can guard it.

  **The clock itself is not settable here.** `nerves_time` brings it from NTP and a
  person has nothing useful to say about it. What a person knows, and the device cannot
  work out, is which part of the world it is sitting in.
  """

  use Ash.Resource, otp_app: :pifi, domain: PiFi.Device

  alias PiFi.Device.Timezone

  actions do
    default_accept []

    action :report, :map do
      description """
      The zone that this device is in, and the time there now.

      `now` is a `DateTime` already shifted, so a caller formats it and shifts nothing.
      `common` is a list for a person to pick from, and not the set of what is allowed.
      """

      run fn _input, _context ->
        {:ok,
         %{
           timezone: Timezone.get(),
           now: Timezone.now(),
           common: Timezone.common(),
           default?: Timezone.get() == Timezone.default()
         }}
      end
    end

    action :set_timezone, :atom do
      description """
      Say which part of the world this device is in.

      It takes an IANA name such as `Pacific/Auckland`, and it refuses one that the
      database does not carry rather than leaving a device reading the wrong hour. An
      offset is not a zone: `+12` is wrong for half the year in a place that keeps
      daylight saving.
      """

      argument :timezone, :string, allow_nil?: false

      run fn input, _context ->
        case Timezone.put(input.arguments.timezone) do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end
end
