import Config

config :pifi, Oban, testing: :manual
config :pifi, :switch_off_marker, Path.join(System.tmp_dir!(), "pifi-switch-off-test")
config :pifi, :airplay_data_dir, Path.join(System.tmp_dir!(), "pifi-airplay-test")

config :pifi, PiFi.Repo,
  database: Path.join(__DIR__, "../test#{System.get_env("MIX_TEST_PARTITION")}.db"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  default_transaction_mode: :deferred

config :pifi, PiFi.Radio.RadioBrowser,
  plug: {Req.Test, PiFi.Radio.RadioBrowser},
  retry: false

config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true
config :phoenix, plug_init_mode: :runtime
config :logger, level: :warning

config :pifi,
       PiFiWeb.Endpoint,
       http: [ip: {127, 0, 0, 1}, port: 4002],
       secret_key_base: "e/KiUxdWgXS83BO8IbGxe4QJ5ax1a3YYkIfubRYYQK+APlhyJf6V8ZjehvhKObC1",
       server: false
