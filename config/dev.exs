import Config

config :pifi, PiFi.Repo,
  database: Path.join(__DIR__, "../dev.db"),
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :ash, policies: [show_policy_breakdowns?: true]
config :phoenix, stacktrace_depth: 20, plug_init_mode: :runtime
config :logger, default_formatter: [format: "[$level] $message
"]
config :pifi, dev_routes: true

config :pifi,
       PiFiWeb.Endpoint,
       http: [ip: {0, 0, 0, 0}, port: 4000],
       check_origin: false,
       debug_errors: true

if Mix.target() == :host do
  config :pifi,
         PiFiWeb.Endpoint,
         secret_key_base: "pXfI5KnH7ehUWe6JjHZ2r1GzxdF7cX9F50DAa8z9/AKKabtJSx7uK10bzn05jrco",
         code_reloader: true,
         watchers: [
           esbuild: {Esbuild, :install_and_run, [:pifi, ["--sourcemap=inline", "--watch"]]},
           tailwind: {Tailwind, :install_and_run, [:pifi, ["--watch"]]}
         ],
         live_reload: [
           web_console_logger: true,
           patterns: [
             ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
             ~r"lib/.*_web/router\.ex$",
             ~r"lib/.*_web/(controllers|live|components)/.*\.(ex|heex)$"
           ]
         ]
end
