import Config

if System.get_env("PHX_SERVER") do
  config :my_hi_fi, MyHiFiWeb.Endpoint, server: true
end

config :my_hi_fi, MyHiFiWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :my_hi_fi, MyHiFiWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base

  config :my_hi_fi, MyHiFi.Repo, pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
end
