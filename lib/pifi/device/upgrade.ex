defmodule PiFi.Device.Upgrade do
  @moduledoc """
  The firmware that this device runs, and the one that it could run.

  A tag of the form `v1.2.3` starts a build, and that build attaches a `.fw` for each
  target to a release of the forge. This device reads that list once a day, tells a
  person when a newer version landed, and writes it to the card when they press install.

  **A device upgrades because a person said so.** A stereo that restarted itself in the
  middle of a record is a stereo that a person stops trusting, and an upgrade that
  nobody watched is one that nobody can undo. `PiFi.Device.Upgrade.Check` finds the
  release and the settings page holds the control.

  The resource stores no data of its own, so it needs no data layer.
  `PiFi.Device.Upgrade.Server` holds the answer of the last check and the progress of an
  upgrade that is running, in the way that `PiFi.Player` holds the playback state.

  ## Where each piece lives

  - `PiFi.Device.Upgrade.Forge` reads the releases of the forge.
  - `PiFi.Device.Upgrade.Install` writes one to the card and reboots.
  - `PiFi.Device.Upgrade.Check` is the daily job.
  """

  use Ash.Resource, otp_app: :pifi, domain: PiFi.Device

  alias PiFi.Device.Upgrade.Server

  # The name that the build gives the firmware of this target. See the
  # `nerves-app` workflow, which names it `<repository>-<target>.fw`.
  @firmware_name "pifi-#{Mix.target()}.fw"

  @version Mix.Project.config()[:version]

  @state_fields [
    running: [type: :string, allow_nil?: false],
    available: [type: :string, allow_nil?: true],
    notes: [type: :string, allow_nil?: false],
    checked_at: [type: :utc_datetime_usec, allow_nil?: true],
    state: [type: :atom, allow_nil?: false],
    percent: [type: :integer, allow_nil?: false],
    reason: [type: :string, allow_nil?: true]
  ]

  actions do
    default_accept []

    action :report, :map do
      description """
      What this device knows about the newest firmware.

      It asks the forge nothing. `state` is `:idle`, `:installing`, `:installed` or
      `:failed`, and `available` is `nil` for a device that is already up to date.
      """

      # A generic action does not cast what it returns. These fields therefore describe
      # the shape for a reader and for an API extension, and they enforce nothing.
      constraints fields: @state_fields

      run fn _input, _context -> {:ok, Server.report()} end
    end

    action :check, :map do
      description """
      Ask the forge now, and report what it said.

      A person who read that a version landed will not wait a day for the schedule.
      """

      constraints fields: @state_fields

      run fn _input, _context -> Server.check() end
    end

    action :install, :atom do
      description """
      Write the newest firmware to the card, and restart.

      **It answers before the work finishes**, because the work takes minutes.
      `PiFi.Event.Device.UpgradeChanged` carries the progress, and the device reboots
      when it is done.
      """

      run fn _input, _context ->
        case Server.install() do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  @doc """
  The version that this firmware was built as.

      iex> PiFi.Device.Upgrade.running_version() |> Version.parse() |> elem(0)
      :ok
  """
  @spec running_version() :: String.t()
  def running_version, do: @version

  @doc """
  The name that a release gives the firmware of this target.

      iex> PiFi.Device.Upgrade.firmware_name() =~ ~r/^pifi-.*\\.fw$/
      true
  """
  @spec firmware_name() :: String.t()
  def firmware_name, do: @firmware_name

  @doc """
  The address of the newest release of this firmware.

  A person who builds this for another forge names their own in `config/config.exs`.
  """
  @spec releases_url() :: String.t()
  def releases_url, do: Application.fetch_env!(:pifi, __MODULE__)[:releases_url]

  @doc """
  Where a firmware waits while this device checks it.

  The application data partition is the only writable storage, and it mounts at `/root`
  on a target. See `PiFi.Device.Storage`.
  """
  @spec download_path() :: String.t()
  def download_path, do: Application.fetch_env!(:pifi, __MODULE__)[:download_path]
end
