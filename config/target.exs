import Config

# Use Ringlogger as the logger backend and remove :console.
# See https://ring-logger.hexdocs.pm/readme.html for more information on
# configuring ring_logger.

config :logger, backends: [RingLogger]

# Use shoehorn to start the main application. See the shoehorn
# library documentation for more control in ordering how OTP
# applications are started and handling failures.

config :shoehorn, init: [:nerves_runtime, :nerves_pack]

# Enable the system startup guard to check that all OTP applications
# started. If they didn't and you're on a Nerves system that supports
# test runs of new firmware, the firmware will automatically roll
# back to the previous version. Delete this if implementing your own
# way of validating that firmware is good.
config :nerves_runtime, startup_guard_enabled: true

# Erlinit can be configured without a rootfs_overlay. See
# https://github.com/nerves-project/erlinit/ for more information on
# configuring erlinit.

# Advance the system clock on devices without a real-time clock.
#
# MyHiFi: two more settings, so a restart leaves evidence behind.
#
# ramoops keeps a reserved part of RAM through a reset. The `pstore` mount makes
# the record of the last boot readable at /sys/fs/pstore.
# `MyHiFi.PersistentLogger` writes the log of this firmware to /dev/pmsg0, which
# lands in the same place and costs no write to the SD card.
#
# `shutdown_report` names a file that erlinit writes when the VM exits in an
# orderly way. A hard reset gives no chance to write it, and a crash of the VM
# does.
# `rootfs_overlay/etc/asound.conf` holds the `rate48` definition, so a target build
# can name it and a host build cannot. See `MyHiFi.Output.Alsa.sink_spec/1` for the
# fault of the USB controller that it works around.
config :my_hi_fi, :alsa_rate48?, true

config :nerves, :erlinit,
  update_clock: true,
  mount: "pstore:/sys/fs/pstore:pstore:nodev,noexec,nosuid:",
  shutdown_report: "/root/shutdown_report.txt"

# SSH belongs to a development firmware only. A stereo component in a home needs
# no shell, and a production firmware therefore accepts no connection.
#
# `nerves_ssh` starts a daemon only when it holds an application environment. A
# production build writes none of the configuration below, so the daemon never
# starts, and the build asks for no key. See `NervesSSH.Application.start/2`.
#
# * See https://nerves-ssh.hexdocs.pm/readme.html for general SSH configuration
# * See https://ssh-subsystem-fwup.hexdocs.pm/readme.html for firmware updates
development_firmware? = Mix.env() == :dev

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

# Configure the network using vintage_net
#
# Update regulatory_domain to your 2-letter country code E.g., "US"
#
# See https://github.com/nerves-networking/vintage_net for more information
# The wizard makes the access point name from the hostname, and the hostname is
# `nerves-<serial>`. A person looks for the name of the product instead.
config :vintage_net_wizard, ssid: "myhifi"

config :vintage_net,
  # A real country code gives the correct channel list. Access point mode needs
  # it. "00" is the world domain, and it allows fewer channels.
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
  # The `hosts` key specifies what hostnames mdns_lite advertises.  `:hostname`
  # advertises the device's hostname.local. For the official Nerves systems, this
  # is "nerves-<4 digit serial#>.local".  The `"nerves"` host causes mdns_lite
  # to advertise "nerves.local" for convenience. If more than one Nerves device
  # is on the network, it is recommended to delete "nerves" from the list
  # because otherwise any of the devices may respond to nerves.local leading to
  # unpredictable behavior.

  hosts: [:hostname, "nerves"],
  ttl: 120,

  # Advertise the following services over mDNS.
  # A production firmware runs no SSH daemon, so it announces no SSH service. It
  # announces the web interface instead, because that is the way to the device.
  services: mdns_services

# The application data partition mounts at /root on a Nerves target, and it is
# the only writable storage. See the erlinit.config of the Nerves system.
config :my_hi_fi, MyHiFi.Repo, database: "/root/my_hi_fi.db"

config :my_hi_fi, MyHiFiWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 80],
  server: true,
  # A device answers on its IP address, on nerves.local, and on
  # nerves-<serial>.local. An origin check uses one configured host only. Such a
  # check therefore rejects the LiveView socket.
  check_origin: false

# Import target specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# Uncomment to use target specific configurations

# import_config "#{Mix.target()}.exs"
