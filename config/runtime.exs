import Config

if System.get_env("PHX_SERVER") do
  config :my_hi_fi, MyHiFiWeb.Endpoint, server: true
end

if port = System.get_env("PORT") do
  config :my_hi_fi, MyHiFiWeb.Endpoint, http: [port: String.to_integer(port)]
end

# On a target the firmware makes its own secret and keeps it. See
# `MyHiFi.SecretKeyBase`. This is the manual method for a test or a single build.
if secret_key_base = System.get_env("SECRET_KEY_BASE") do
  config :my_hi_fi, MyHiFiWeb.Endpoint, secret_key_base: secret_key_base
end
