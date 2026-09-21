import Config

# Use Ringlogger as the logger backend and remove :console.
# See https://ring-logger.hexdocs.pm/readme.html for more information on
# configuring ring_logger.

# **The log of a device holds 1024 lines, and a line for each request fills it.** A
# Plex controller asked a board for a path that no player serves on 2026-09-15, it
# asked again for each answer of 404, and 1020 of those lines pushed out every error
# that a person needed to read. The level is therefore `info` here, where the default
# of Logger is `debug`, so a line that helps a developer never costs a person the log
# of their device. A developer reads the rest with `RingLogger.attach(level: :debug)`.
config :logger, backends: [RingLogger], level: :info

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

# The hardware that a person sees and touches, and that this firmware knows how to
# drive. A name here does not start anything: the same image runs on a board with a
# screen and on a board with none, so each peripheral is out of use until a person
# names it on the settings page. See `PiFi.Peripheral`.
config :pifi,
  peripherals: [
    {PiFi.Peripheral.PiTft, []},
    {PiFi.Peripheral.PirateAudio, []},
    {PiFi.Peripheral.Battery, []},
    {PiFi.Peripheral.ActivityLed, []}
  ]

# Erlinit can be configured without a rootfs_overlay. See
# https://github.com/nerves-project/erlinit/ for more information on
# configuring erlinit.

# Advance the system clock on devices without a real-time clock.
#
# PiFi: two more settings, so a restart leaves evidence behind.
#
# ramoops keeps a reserved part of RAM through a reset. The `pstore` mount makes
# the record of the last boot readable at /sys/fs/pstore.
# `PiFi.PersistentLogger` writes the log of this firmware to /dev/pmsg0, which
# lands in the same place and costs no write to the SD card.
#
# `shutdown_report` names a file that erlinit writes when the VM exits in an
# orderly way. A hard reset gives no chance to write it, and a crash of the VM
# does.
# `rootfs_overlay/etc/asound.conf` holds the `rate48` definition, so a target build
# can name it and a host build cannot. See `PiFi.Output.Alsa.sink_spec/1` for the
# fault of the USB controller that it works around.
config :pifi, :alsa_rate48?, true

config :nerves, :erlinit,
  update_clock: true,
  mount: "pstore:/sys/fs/pstore:pstore:nodev,noexec,nosuid:",
  shutdown_report: "/root/shutdown_report.txt"

# SSH on the local network belongs to a development firmware only. A stereo
# component in a home listens on no port that a person did not ask for, so a
# production firmware opens none.
#
# **A production board is therefore one way, and that is the deal.** It takes a new
# firmware from the releases of the forge, and a board that will not boot needs the SD
# card in a hand. See `PiFi.Device.Upgrade`.
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
# `nerves-<serial>`. A person looks for the name that they gave the device instead, so
# `PiFi.Setup` writes `config :vintage_net_wizard, ssid: ...` at the moment that it
# starts the wizard. A name here would take the place of that one.

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

  #
  # **`PiFi.Device.Identity.announce/0` replaces this list at each boot.** It names
  # the device first, so the advertisement of the web service carries the name that a
  # person gave, and `nerves.local` goes for the reason above.
  hosts: [:hostname, "nerves"],
  ttl: 120,

  # Advertise the following services over mDNS.
  # A production firmware runs no SSH daemon, so it announces no SSH service. It
  # announces the web interface instead, because that is the way to the device.
  services: mdns_services

# The application data partition mounts at /root on a Nerves target, and it is
# the only writable storage. See the erlinit.config of the Nerves system.
#
# **`cache_size` and `pool_size` decide how much memory SQLite may hold, and the
# product of the two is what matters.** Each connection holds a page cache of its own,
# and it fills that cache the first time it reads a table. A measurement on 2026-09-07
# showed each query of a browse page adding 38 MB, whatever the number of rows that it
# gave back: a count of one favourite cost the same as a count of 4334 albums, because
# the cost is the pages that the read touches.
#
# `ecto_sqlite3` gives `cache_size` the value -64000, which is 62.5 MB for each
# connection, and it says that this is to speed up access of data. That is 32 times the
# 2 MB that SQLite itself uses, and with ten connections it is a ceiling of 625 MB on a
# board where Linux sees 363.9 MB. The whole database is 57 MB, so one connection could
# hold all of it twice.
#
# -4000 is 4 MB for each connection, and four connections make a ceiling of 16 MB. The
# cost is that a read of a large table asks the card for more pages, and the card is
# slower than memory.
# **`busy_timeout` moved to `config/config.exs`**, because a laptop needs it as much as
# a board does and only the board was getting it. That file holds the reasoning.
#
# **None of this takes the place of writing less.** `PiFi.Cache.Touches` is what removed
# 25 writes for each list that a person opens.
config :pifi, PiFi.Repo,
  database: "/root/pifi.db",
  cache_size: -4_000,
  pool_size: 10

# **Two jobs at a time, because a job holds a connection while it runs**, and because a
# board of four cores must keep enough of them for the sound. The queue of ten that
# `config/config.exs` names would leave neither.
#
# **`artwork` is one at a time, and it is a queue of its own.** A read of a library asks
# for a picture of every container that it writes, so that worker arrives in thousands
# while every other job arrives in ones, and each one reads a picture and then runs
# `vipsthumbnail` over the bytes. Two of them at once was measured on a board on
# 2026-09-14, during a read of a library of 63,010 tracks.
#
# **Lowering `default` instead would have starved the audio of a mark.**
# `cache_audio` of `PiFi.Playback.Item` is in that queue, and so is a read of a
# library that runs for 80 minutes, so a person who marked an album would have waited
# for the read before a note of it reached the card.
#
# **This list replaces the one of `config/config.exs`, and does not add to it**, so a
# queue that is absent here does not run on a device. That is why `artwork` is named in
# both files.
config :pifi, Oban, queues: [default: 2, artwork: 1]

# **`Oban.Met` polls the job table about once a second, and each poll reads the card.**
# A trace of the database over three minutes on a board on 2026-09-16 counted 169 of
# this gauge query, at 52 ms each:
#
#     SELECT state, queue, count(id) FROM oban_jobs WHERE state IN (...) GROUP BY state, queue
#
# That is about 5% of one core and a read of the card each second.
#
# **A production firmware shows those numbers to no person.** `PiFiWeb.Router`
# mounts the `/oban` dashboard behind `dev_routes`, and `config/dev.exs` is the only
# file that sets that key. A development firmware therefore keeps the poll, in the
# same way that it keeps the SSH daemon above.
config :oban_met, auto_start: development_firmware?

config :pifi, PiFiWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 80],
  server: true,
  # A device answers on its IP address, on nerves.local, and on
  # nerves-<serial>.local. An origin check uses one configured host only. Such a
  # check therefore rejects the LiveView socket.
  check_origin: false

# **NBPR publishes no artefact for a custom Nerves system**, so each build of this
# firmware builds the 6 packages from source, and that takes 10 minutes. The registry
# that this names is where a build puts the result, so the next build reads it.
#
# **A build that holds no credential must not publish.** `NBPR.OCI.Client` reads
# `NBPR_REGISTRY_USERNAME` and `NBPR_REGISTRY_TOKEN`, and `mix nbpr.fetch` stops with
# `registry_credentials_required` when it finishes a package and finds neither one.
# The CI container holds neither, so each push to `main` failed before `mix firmware`
# ran at all. An absent secret turns the feature off, and it does not stop the build.
registry_username = "NBPR_REGISTRY_USERNAME" |> System.get_env() |> to_string() |> String.trim()

registry_token = "NBPR_REGISTRY_TOKEN" |> System.get_env() |> to_string() |> String.trim()

config :nbpr,
  registry: "harton.dev/mypihifiguy/myhifi",
  publish_after_build: registry_username != "" and registry_token != ""

# Import target specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# Uncomment to use target specific configurations

# import_config "#{Mix.target()}.exs"
