import Config

config :logger, level: :info

config :my_hi_fi,
       MyHiFiWeb.Endpoint,
       force_ssl: [rewrite_on: [:x_forwarded_proto]],
       exclude: [hosts: ["localhost", "127.0.0.1"]]
