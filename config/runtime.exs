import Config

if System.get_env("PHX_SERVER") do
  config :my_hi_fi, MyHiFiWeb.Endpoint, server: true
end

if port = System.get_env("PORT") do
  config :my_hi_fi, MyHiFiWeb.Endpoint, http: [port: String.to_integer(port)]
end

if config_env() == :prod do
  # On a Nerves target the application data partition mounts at /root. It is the
  # only writable storage, and erlinit mounts it before the VM starts.
  data_dir = System.get_env("MYHIFI_DATA_DIR", "/root")
  secret_path = Path.join(data_dir, "secret_key_base")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      case File.read(secret_path) do
        {:ok, secret} ->
          secret

        {:error, _} ->
          secret = 48 |> :crypto.strong_rand_bytes() |> Base.encode64(padding: false)
          File.mkdir_p(data_dir)
          # A host build has no data partition and serves no request, so a secret
          # that lasts for one run is enough there. On a device a failed write
          # only means that signed cookies do not survive a reboot.
          File.write(secret_path, secret)
          secret
      end

  config :my_hi_fi, MyHiFiWeb.Endpoint, secret_key_base: secret_key_base
end
