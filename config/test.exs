import Config

config :phoenix, plug_init_mode: :runtime
config :logger, level: :warning

config :my_hi_fi,
       MyHiFiWeb.Endpoint,
       http: [ip: {127, 0, 0, 1}, port: 4002],
       secret_key_base: "e/KiUxdWgXS83BO8IbGxe4QJ5ax1a3YYkIfubRYYQK+APlhyJf6V8ZjehvhKObC1",
       server: false
