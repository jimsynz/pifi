defmodule MyHiFi.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args), do: start_app()

  defp start_normally do
    put_device_secrets()
    migrate()

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
        MyHiFi.Player,
        MyHiFiWeb.Endpoint
      ] ++ target_children()

    # `MyHiFi.Radio.FirstSync` comes after Oban, because it puts a job in the
    # queue.

    Supervisor.start_link(children, supervisor_options())
  end

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
        MyHiFi.Radio.FirstSync
      ]
    end
  end
end
