import Config

# Add configuration that is only needed when running on the host here.

config :nerves_runtime,
  kv_backend:
    {Nerves.Runtime.KVBackend.InMemory,
     contents: %{
       # The KV store on Nerves systems is typically read from UBoot-env, but
       # this allows us to use a pre-populated InMemory store when running on
       # host for development and testing.
       #
       # https://nerves-runtime.hexdocs.pm/readme.html#using-nerves_runtime-in-tests
       # https://nerves-runtime.hexdocs.pm/readme.html#nerves-system-and-firmware-metadata

       "nerves_fw_active" => "a",
       "a.nerves_fw_architecture" => "generic",
       "a.nerves_fw_description" => "N/A",
       "a.nerves_fw_platform" => "host",
       "a.nerves_fw_version" => "0.0.0"
     }}

config :nerves_uevent, manage_udev: true

# A host keeps one salt, so a LiveView session continues after a restart of the
# server. A target makes its own and keeps it under `/root`. See
# `PiFi.DeviceSecrets`.
config :pifi, PiFiWeb.Endpoint, live_view: [signing_salt: "EhXdl2qH"]

# `/root` is the writable partition of a target and the home of another person on a
# host, so a host writes somewhere that it may. A host applies no firmware in any case:
# see `PiFi.Device.Upgrade.Install`.
config :pifi, PiFi.Device.Upgrade, download_path: System.tmp_dir!()
