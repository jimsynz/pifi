import Config

config :my_hi_fi, Oban, testing: :manual

config :my_hi_fi, MyHiFi.Repo,
  database: Path.join(__DIR__, "../test#{System.get_env("MIX_TEST_PARTITION")}.db"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true
config :phoenix, plug_init_mode: :runtime
config :logger, level: :warning

config :my_hi_fi,
       MyHiFiWeb.Endpoint,
       http: [ip: {127, 0, 0, 1}, port: 4002],
       secret_key_base: "e/KiUxdWgXS83BO8IbGxe4QJ5ax1a3YYkIfubRYYQK+APlhyJf6V8ZjehvhKObC1",
       server: false
