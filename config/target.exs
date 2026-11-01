import Config

development_firmware? = Mix.env() == :dev

config :logger,
  backends: [RingLogger],
  level: if(development_firmware?, do: :debug, else: :info)

if development_firmware? do
  config :logger, RingLogger, max_size: 4096
end

config :shoehorn, init: [:nerves_runtime, :nerves_pack]

config :nerves_runtime, startup_guard_enabled: true

config :pifi,
  peripherals: [
    {PiFi.Peripheral.PiTft, []},
    {PiFi.Peripheral.PirateAudio, []},
    {PiFi.Peripheral.Battery, []},
    {PiFi.Peripheral.ActivityLed, []},
    {PiFi.Peripheral.HapticKnobs, []}
  ]

config :pifi, :alsa_rate48?, true

config :nerves, :erlinit,
  update_clock: true,
  mount: "pstore:/sys/fs/pstore:pstore:nodev,noexec,nosuid:",
  shutdown_report: "/root/shutdown_report.txt"

if development_firmware? do
  keys =
    System.user_home!()
    |> Path.join(".ssh/id_{rsa,ecdsa,ed25519,nerves}.pub")
    |> Path.wildcard()

  if keys == [],
    do:
      Mix.raise("""
      No SSH public keys found in ~/.ssh. A development firmware gives an IEx
      prompt over SSH, and it needs an authorized key for that.

      Build a production firmware with MIX_ENV=prod for a device with no shell.
      """)

  config :nerves_ssh, authorized_keys: Enum.map(keys, &File.read!/1)
end

config :vintage_net,
  regulatory_domain: "NZ",
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0",
     %{
       type: VintageNetEthernet,
       ipv4: %{method: :dhcp}
     }},
    {"wlan0", %{type: VintageNetWiFi}}
  ]

web_service = %{protocol: "http", transport: "tcp", port: 80}

shell_services = [
  %{protocol: "ssh", transport: "tcp", port: 22},
  %{protocol: "sftp-ssh", transport: "tcp", port: 22},
  %{protocol: "epmd", transport: "tcp", port: 4369}
]

mdns_services =
  if development_firmware?,
    do: [web_service | shell_services],
    else: [web_service]

config :mdns_lite,
  hosts: [:hostname, "pifi"],
  ttl: 120,
  services: mdns_services

config :pifi, PiFi.Repo,
  database: "/root/pifi.db",
  cache_size: -4_000,
  pool_size: 10

config :pifi, Oban, queues: [default: 2, artwork: 1]

config :oban_met, auto_start: development_firmware?

config :pifi, PiFiWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 80],
  server: true,
  check_origin: false

registry_username = "NBPR_REGISTRY_USERNAME" |> System.get_env() |> to_string() |> String.trim()
registry_token = "NBPR_REGISTRY_TOKEN" |> System.get_env() |> to_string() |> String.trim()

config :nbpr,
  registry: "harton.dev/mypihifiguy/myhifi",
  publish_after_build: registry_username != "" and registry_token != ""
