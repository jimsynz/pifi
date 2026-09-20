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

  alias PiFi.Device.Upgrade.Server

  @doc false
  @impl Oban.Worker
  def perform(_job) do
    _report = Server.check()

    :ok
  end
end
