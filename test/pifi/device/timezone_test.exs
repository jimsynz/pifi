defmodule PiFi.Device.TimezoneTest do
  @moduledoc """
  Where the device thinks it is, and what that changes.

  **Everything this firmware stores is UTC.** These cover the one place that turns a
  stored moment into the time on a person's wall, and the one decision that reads it.
  """

  use PiFi.DataCase, async: false

  doctest PiFi.Device.Timezone, import: true

  alias PiFi.Device.Timezone

  setup do
    on_exit(fn -> Timezone.put(Timezone.default()) end)

    :ok
  end

  describe "a device that no person told" do
    test "reads UTC, which is the time it knows rather than one it guessed" do
      assert Timezone.get() == "Etc/UTC"
      assert Timezone.at(~U[2026-09-21 04:17:00Z]).hour == 4
    end

    # A person needs to see that the hour is not theirs, or they read the wrong time and
    # have no way to tell.
    test "says so after the times that it draws" do
      assert Timezone.suffix(Timezone.get()) == " UTC"
    end
  end

  describe "a device that a person told" do
    test "reads the time where they are" do
      assert :ok = Timezone.put("Pacific/Auckland")

      # New Zealand keeps standard time in September, so this is +12.
      assert Timezone.at(~U[2026-09-21 04:17:00Z]).hour == 16
      assert Timezone.suffix(Timezone.get()) == ""
    end

    # **An offset is wrong twice a year, and a name is not.** This is the whole reason
    # the setting takes a place rather than a number.
    test "follows the daylight saving rule of that place" do
      assert :ok = Timezone.put("Pacific/Auckland")

      winter = Timezone.at(~U[2026-07-01 00:00:00Z])
      summer = Timezone.at(~U[2026-12-01 00:00:00Z])

      assert winter.utc_offset + winter.std_offset == 12 * 3600
      assert summer.utc_offset + summer.std_offset == 13 * 3600
    end

    test "a place that the database does not carry is refused" do
      assert {:error, :time_zone_not_found} = Timezone.put("Middle/Earth")
      assert Timezone.get() == "Etc/UTC"
    end

    # IANA removes a name now and then, and a device that kept an unknown one would
    # raise in every page that draws a time.
    test "a name that stopped existing reads as the default" do
      PiFi.Settings.put!(Timezone.key(), "Some/Place")

      assert Timezone.get() == "Etc/UTC"
    end
  end

  # **The crontab cannot answer this**, because `PiFi.Application` builds the Oban
  # configuration before the supervisor starts the Repo, so a zone that lives in the
  # settings is unreadable at the moment a crontab would have to be given one. The
  # worker therefore runs every hour and decides.
  describe "when the device looks for a new firmware" do
    alias PiFi.Device.Upgrade.Check

    test "at the named hour of the morning where the person is" do
      assert :ok = Timezone.put("Pacific/Auckland")

      # 16:17 UTC is 04:17 the next morning in Auckland.
      assert Check.due?(~U[2026-09-21 16:17:00Z])
      refute Check.due?(~U[2026-09-21 04:17:00Z])
    end

    test "and on UTC for a device that no person told" do
      assert Check.due?(~U[2026-09-21 04:17:00Z])
      refute Check.due?(~U[2026-09-21 16:17:00Z])
    end

    # A person who sets their zone should not have to reboot for the overnight work to
    # move with them, which a crontab fixed at boot would have made them do.
    test "it moves as soon as a person changes the zone" do
      refute Check.due?(~U[2026-09-21 16:17:00Z])

      assert :ok = Timezone.put("Pacific/Auckland")

      assert Check.due?(~U[2026-09-21 16:17:00Z])
    end
  end
end
