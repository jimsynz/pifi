defmodule PiFi.Radio.Sync do
  @moduledoc """
  The copy of the Radio Browser station list into the catalogue.

  This resource stores no data. `PiFi.Playback.Item` keeps the stations, and this is
  the place that the schedule and the control of the settings page name.
  `PiFi.Playback.Player` is a resource of the same shape. An API extension serves an
  action and not a function, and a policy guards an action and not a function, which is
  why each one is a resource.
  """

  use Ash.Resource,
    otp_app: :pifi,
    domain: PiFi.Radio,
    extensions: [AshOban]

  oban do
    scheduled_actions do
      # A station list changes slowly, and each run asks the service for a whole
      # country. One time each week is often enough, and it is kind to a service
      # that asks nothing for its work.
      schedule :sync_from_remote, "0 4 * * 0" do
        action :sync_from_remote
        worker_module_name PiFi.Radio.Sync.Workers.FromRemote
        queue :default
        max_attempts 3
      end
    end
  end

  actions do
    default_accept []

    action :sync_from_remote, :map do
      description """
      Read the station list of each chosen country, and write it into the catalogue.

      It returns the number of stations that it wrote, the countries that failed, and
      whether a person has taken the source out of use.
      """

      argument :countries, {:array, :string}, allow_nil?: true

      run PiFi.Radio.Sync.FromRemote
    end
  end
end
