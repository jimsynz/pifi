defmodule PiFi.Device.Upgrade.Check do
  @moduledoc """
  Asks the forge once a day whether a newer firmware landed.

  **A home stereo does not need to know within the hour.** A release is a thing that
  happens a few times a month, and a person who read that one landed presses the control
  on the settings page rather than wait. One request a day is nothing to the forge and
  nothing to the card.

  A device with no network answers nothing, and the next day asks again.
  `PiFi.Device.Upgrade.Server` keeps the answer of the last check that worked, so a
  person sees what was true rather than an empty page.
  """

  use Oban.Worker, max_attempts: 1, queue: :default

  alias PiFi.Device.Timezone
  alias PiFi.Device.Upgrade.Server

  # The hour of the morning to ask in, on the clock of the person. **The hour is not
  # midnight.** Every device of this product would ask the forge in the same minute, and
  # a person who upgrades at 3 in the morning is asleep beside a stereo that reboots.
  @hour 4

  @doc """
  The hour of the local morning that this asks in.

      iex> PiFi.Device.Upgrade.Check.hour()
      4
  """
  @spec hour() :: 0..23
  def hour, do: @hour

  @doc """
  Whether this is the hour to ask in, on the clock of the person.

  **The crontab cannot answer this, which is why the worker does.** Oban reads its
  crontab as the firmware boots, and `PiFi.Application` builds that list before the
  supervisor starts the Repo, so a time zone that lives in the settings is unreadable at
  the moment a zone would have to be given. A person also sets theirs long after the
  boot, and a crontab that was fixed then would keep asking on the old clock until the
  next restart.

  So the crontab runs this every hour in UTC and this decides. An hour of work for a
  read of one setting, once an hour, and it is right through a change of zone and
  through both ends of daylight saving.
  """
  @spec due?(DateTime.t()) :: boolean()
  def due?(%DateTime{} = moment), do: Timezone.at(moment).hour == @hour

  @doc false
  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    if due?(job.scheduled_at || DateTime.utc_now()) do
      _report = Server.check()
    end

    :ok
  end
end
