import Config

if System.get_env("PHX_SERVER") do
  config :pifi, PiFiWeb.Endpoint, server: true
end

if port = System.get_env("PORT") do
  config :pifi, PiFiWeb.Endpoint, http: [port: String.to_integer(port)]
end

if secret_key_base = System.get_env("SECRET_KEY_BASE") do
  config :pifi, PiFiWeb.Endpoint, secret_key_base: secret_key_base
end
