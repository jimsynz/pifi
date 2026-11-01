import Config

config :nerves_runtime,
  kv_backend:
    {Nerves.Runtime.KVBackend.InMemory,
     contents: %{
       "nerves_fw_active" => "a",
       "a.nerves_fw_architecture" => "generic",
       "a.nerves_fw_description" => "N/A",
       "a.nerves_fw_platform" => "host",
       "a.nerves_fw_version" => "0.0.0"
     }}

config :nerves_uevent, manage_udev: true

config :pifi, PiFiWeb.Endpoint, live_view: [signing_salt: "EhXdl2qH"]
config :pifi, PiFi.Device.Upgrade, download_path: System.tmp_dir!()
