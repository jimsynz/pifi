import Config

config :my_hi_fi, MyHiFi.Repo,
  database: "../path/to/your.db",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :ash, policies: [show_policy_breakdowns?: true]
config :phoenix, stacktrace_depth: 20, plug_init_mode: :runtime
config :logger, default_formatter: [format: "[$level] $message
"]
config :my_hi_fi, dev_routes: true

config :my_hi_fi,
       MyHiFiWeb.Endpoint,
       http: [ip: {0, 0, 0, 0}, port: 4000],
       check_origin: false,
       code_reloader: true,
       debug_errors: true,
       secret_key_base: "pXfI5KnH7ehUWe6JjHZ2r1GzxdF7cX9F50DAa8z9/AKKabtJSx7uK10bzn05jrco",
       watchers: [
         esbuild: {Esbuild, :install_and_run, [:my_hi_fi, ["--sourcemap=inline", "--watch"]]},
         tailwind: {Tailwind, :install_and_run, [:my_hi_fi, ["--watch"]]}
       ],
       live_reload: [
         web_console_logger: true,
         patterns: [
           ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
           ~r"lib/.*_web/router\.ex$",
           ~r"lib/.*_web/(controllers|live|components)/.*\.(ex|heex)$"
         ]
       ]
