defmodule PiFi.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias PiFi.Device.Identity
  alias PiFi.Player.Download
  alias PiFi.Plex.Companion

  @impl true
  def start(_type, _args), do: start_app()

  defp start_normally do
    put_device_secrets()
    migrate()
    # A download writes its file outside the cache, so no row names that file and no
    # eviction can see it. An interruption of the power leaves one behind, and this
    # is the only thing that reclaims it. See `PiFi.Player.Download`.
    Download.sweep()

    children =
      [
        PiFi.Repo,
        # Almost every other child reads a setting while it starts, and this holds the
        # answers. See `PiFi.Settings.Cache`.
        PiFi.Settings.Cache,
        PiFiWeb.Telemetry,
        {Oban, oban_config()},
        {Phoenix.PubSub, [name: PiFi.PubSub]},
        {Registry, keys: :unique, name: Download.Registry},
        {DynamicSupervisor, strategy: :one_for_one, name: Download.Supervisor},
        # It holds `aplay` across more than one pipeline, so it comes before the player
        # and it outlives every pipeline that the player builds. See
        # `PiFi.Output.APlayPort`.
        PiFi.Output.APlayPort,
        PiFi.Player,
        # An upgrade reads 30 MB and then writes a partition, and the state process must
        # answer a page while that happens. See `PiFi.Device.Upgrade.Server`.
        {Task.Supervisor, name: PiFi.Device.Upgrade.Tasks},
        PiFi.Device.Upgrade.Server,
        PiFi.Peripheral.Supervisor,
        # It starts with no child, in the way that the peripherals do, and
        # `start_enabled/0` below starts the listener. A port that another program holds
        # must not stop the boot. See `PiFi.Plex.Companion`.
        Companion,
        # It listens on a port as well, and it starts with no child for the same
        # reason. See `PiFi.HomeAssistant`.
        PiFi.HomeAssistant,
        PiFiWeb.Endpoint
      ] ++ listening_children() ++ target_children()

    with {:ok, supervisor} <- Supervisor.start_link(children, supervisor_options()) do
      # This comes after the tree and not inside it. A peripheral opens a bus, and a
      # bus with nothing on it gives an error, so one screen that no person wired
      # would stop the start of the whole firmware. See `PiFi.Peripheral`.
      PiFi.Peripheral.start_enabled()

      # **This listens on a port, and no other part of this firmware does.** A person
      # turns it on, so a device that no person asked holds the port closed. See
      # `PiFi.Plex.Companion`.
      Companion.start_enabled()
      PiFi.HomeAssistant.start_enabled()

      # The mDNS advertisement lives in memory, and the name of the device lives on the
      # card, so each boot says the name again. See `PiFi.Device.Identity`.
      Identity.announce()

      {:ok, supervisor}
    end
  end

  # **These act on the player or on the card, and a test must start its own.**
  # Each one is named for the whole node, so a suite that ran them would give every test
  # a listener that it did not ask for: a test of the battery publishes a low cell, this
  # `PiFi.AutoStandby` puts the player in standby for it, and the next test then finds
  # a device that is asleep. That failure came and went with the order of the files.
  #
  # A test that wants one starts it with `ExUnit.Callbacks.start_supervised/1`, which
  # gives one instance for that test and takes it away at the end of it.
  #
  # `PiFi.Cache.Touches` is here for a second reason. It writes from a process of its
  # own, and the sandbox of Ecto gives the connection to the process of the test, so a
  # write of another process needs permission that an async test cannot give. A test
  # that runs no buffer writes each used mark at once, which is the behaviour that every
  # test of the cache reads. See `PiFi.Cache.used/1`.
  if Mix.env() == :test do
    defp listening_children, do: []
  else
    # `PiFi.AutoStandby` and `PiFi.Output.Volume` both read the player, so they come
    # after it.
    defp listening_children,
      do: [
        PiFi.AutoStandby,
        PiFi.Cache.Touches,
        PiFi.DeviceUi,
        PiFi.Output.Volume,
        PiFi.SwitchOff
      ]
  end

  # See https://elixir.hexdocs.pm/Supervisor.html
  # for other strategies and supported options
  defp supervisor_options, do: [strategy: :one_for_one, name: PiFi.Supervisor]

  # `AshOban.config/2` reads the `schedule` block of each resource and puts a line in the
  # crontab for it. **A clock is the wrong condition for the work that needs the
  # network**, and `PiFi.AutoSync` holds the right one, so this takes those lines out
  # again. The `schedule` block stays, because `AshOban.schedule/2` reads it and a
  # scheduled action takes no `false` in the place of its cron.
  defp oban_config do
    :pifi
    |> Application.fetch_env!(:ash_domains)
    |> AshOban.config(Application.fetch_env!(:pifi, Oban))
    |> Keyword.update!(:plugins, &Enum.map(&1, fn plugin -> without_auto_sync(plugin) end))
  end

  defp without_auto_sync({Oban.Plugins.Cron, options}) do
    workers = PiFi.AutoSync.workers()

    # An entry of a crontab names a worker with no options or with them, so this reads
    # the second element and never the shape of the whole tuple.
    {Oban.Plugins.Cron,
     Keyword.update!(options, :crontab, fn crontab ->
       Enum.reject(crontab, &(elem(&1, 1) in workers))
     end)}
  end

  defp without_auto_sync(plugin), do: plugin

  # List all child processes to be supervised
  if Mix.target() == :host do
    defp start_app, do: start_normally()

    defp put_device_secrets, do: :ok
    defp migrate, do: :ok

    defp target_children do
      [
        # Children that only run on the host during development or test.
        # In general, prefer using `config/host.exs` for differences.
        #
        # Starts a worker by calling: Host.Worker.start_link(arg)
        # {Host.Worker, arg},
      ]
    end
  else
    # Setup mode and normal operation cannot happen together, because each one
    # needs port 80. See `PiFi.Setup`.
    defp start_app do
      PiFi.PersistentLogger.attach()
      report_last_boot()

      case PiFi.Setup.start() do
        :running -> Supervisor.start_link([PiFi.Setup.Monitor], supervisor_options())
        :not_needed -> start_normally()
      end
    end

    require Logger

    alias Nerves.Runtime.Heart

    # The reason for a restart is worth knowing, and the log now survives one.
    defp report_last_boot do
      case Heart.status() do
        {:ok, %{wdt_last_boot: reason} = status} ->
          Logger.info(
            "Boot reason #{inspect(reason)}. The heartbeat times out after " <>
              "#{status.heartbeat_timeout} s, and the watchdog after #{status.wdt_timeout} s."
          )

        other ->
          Logger.info("The heart gave no status: #{inspect(other)}")
      end
    end

    defp put_device_secrets, do: PiFi.DeviceSecrets.put()
    defp migrate, do: PiFi.Migrator.migrate()

    defp target_children do
      [
        # The reports of the settings page arrive on the `:device` topic, and no page
        # asks for them on an interval. See `PiFi.Device.Monitor`.
        PiFi.Device.Monitor,
        # It reads the network that the monitor publishes, so it comes after it. It also
        # puts jobs in the queue, so it comes after Oban. See `PiFi.AutoSync`.
        PiFi.AutoSync,
        # An upgrade formats the boot partition, so the boot configuration of a person
        # is gone and this writes it again. It comes last, because it restarts the
        # device when it writes. See `PiFi.Hardware`.
        PiFi.Hardware
      ]
    end
  end
end
