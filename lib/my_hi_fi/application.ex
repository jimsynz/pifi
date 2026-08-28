defmodule MyHiFi.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias MyHiFi.Player.Download

  @impl true
  def start(_type, _args), do: start_app()

  defp start_normally do
    put_device_secrets()
    migrate()
    # A download writes its file outside the cache, so no row names that file and no
    # eviction can see it. An interruption of the power leaves one behind, and this
    # is the only thing that reclaims it. See `MyHiFi.Player.Download`.
    Download.sweep()
    make_queue_table()

    children =
      [
        MyHiFi.Repo,
        MyHiFiWeb.Telemetry,
        {Oban,
         AshOban.config(
           Application.fetch_env!(:my_hi_fi, :ash_domains),
           Application.fetch_env!(:my_hi_fi, Oban)
         )},
        {Phoenix.PubSub, [name: MyHiFi.PubSub]},
        {Registry, keys: :unique, name: Download.Registry},
        {DynamicSupervisor, strategy: :one_for_one, name: Download.Supervisor},
        MyHiFi.Player,
        MyHiFiWeb.Endpoint
      ] ++ target_children()

    # `MyHiFi.Radio.FirstSync` comes after Oban, because it puts a job in the
    # queue.

    Supervisor.start_link(children, supervisor_options())
  end

  # `MyHiFi.Playback.Queue` is on ETS, and the data layer makes the table when
  # something first reads it. The process that owns the table registers its name
  # before it makes the table, so a second caller in that moment is told that the
  # table already exists and then finds none. The player and the web interface can
  # both reach for the queue at once, so this reads it one time and the race cannot
  # happen.
  defp make_queue_table, do: Ash.read!(MyHiFi.Playback.Queue)

  # See https://elixir.hexdocs.pm/Supervisor.html
  # for other strategies and supported options
  defp supervisor_options, do: [strategy: :one_for_one, name: MyHiFi.Supervisor]

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
    # needs port 80. See `MyHiFi.Setup`.
    defp start_app do
      MyHiFi.PersistentLogger.attach()
      report_last_boot()

      case MyHiFi.Setup.start() do
        :running -> Supervisor.start_link([MyHiFi.Setup.Monitor], supervisor_options())
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

    defp put_device_secrets, do: MyHiFi.DeviceSecrets.put()
    defp migrate, do: MyHiFi.Migrator.migrate()

    defp target_children do
      [
        MyHiFi.Radio.FirstSync,
        # The reports of the settings page arrive on the `:device` topic, and no page
        # asks for them on an interval. See `MyHiFi.Device.Monitor`.
        MyHiFi.Device.Monitor
      ] ++
        MyHiFi.Peripheral.child_specs() ++
        [
          # An upgrade formats the boot partition, so the boot configuration of a person
          # is gone and this writes it again. It comes last, because it restarts the
          # device when it writes. See `MyHiFi.Hardware`.
          MyHiFi.Hardware
        ]
    end
  end
end
