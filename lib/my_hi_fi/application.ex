defmodule MyHiFi.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    put_secret_key_base()
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
        MyHiFiWeb.Endpoint
      ] ++ target_children()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MyHiFi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # List all child processes to be supervised
  if Mix.target() == :host do
    defp put_secret_key_base, do: :ok
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
    defp put_secret_key_base, do: MyHiFi.SecretKeyBase.put()
    defp migrate, do: MyHiFi.Migrator.migrate()

    defp target_children do
      [
        # Children for all targets except host
        # Starts a worker by calling: Target.Worker.start_link(arg)
        # {Target.Worker, arg},
      ]
    end
  end
end
