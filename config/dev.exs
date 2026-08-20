import Config

config :my_hi_fi, MyHiFi.Repo,
  database: Path.join(__DIR__, "../dev.db"),
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
       debug_errors: true

# This block holds the configuration for the host only. A device must not get
# these keys.
#
# The esbuild and tailwind programs are not in the image, and code reload needs
# mix. `live_reload` also holds regexes, and `mix release` cannot write a regex
# into the release configuration.
#
# `config/target.exs` cannot remove a key. `Config` merges two keyword lists, so
# an empty list there leaves the original list unchanged. A key must therefore
# not reach a target build in the first place.
if Mix.target() == :host do
  config :my_hi_fi,
         MyHiFiWeb.Endpoint,
         # A dev firmware makes its own secret at each first start, and it keeps
         # the secret under `/root`. See `MyHiFi.SecretKeyBase`. The host keeps
         # this fixed secret, so a session in local development stays valid after
         # a restart.
         secret_key_base: "pXfI5KnH7ehUWe6JjHZ2r1GzxdF7cX9F50DAa8z9/AKKabtJSx7uK10bzn05jrco",
         code_reloader: true,
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
end
