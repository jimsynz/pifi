# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

config :ash_oban, pro?: false
config :ash, default_string_length_count: :codepoints

# **Without this every `DateTime.shift_zone/2` answers `:utc_only_time_zone_database`**,
# and a device that shows a person the time in UTC is a device that shows them the wrong
# time for most of the world. See `PiFi.Device.Timezone`.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# **The whole IANA database is history back to 1970 and rules forward for ever**, and
# each period of each zone becomes a clause in a compiled module. A stereo needs the
# rules of the years that it runs in, so this keeps a window around them and leaves the
# rest out of the firmware.
config :tz,
  reject_periods_before_year: 2020,
  build_dst_periods_until_year: 2040

config :pifi, Oban,
  engine: Oban.Engines.Lite,
  notifier: Oban.Notifiers.PG,
  # `artwork` is one at a time on purpose, and `PiFi.Artwork.Worker` says why.
  queues: [default: 10, artwork: 1],
  repo: PiFi.Repo,
  # A job that finished stays in the table until something removes it, and this device
  # runs for years on an SD card. A week is long enough to read what happened and short
  # enough that the table never grows.
  # **The hour is not midnight.** Every device of this product would ask the forge in
  # the same minute, and a person who upgrades at 3 in the morning is asleep beside a
  # stereo that reboots.
  plugins: [
    # **The hour is the worker's and not the crontab's**, and `PiFi.Device.Upgrade.Check`
    # says why: a crontab is read as the firmware boots, and a person sets their time
    # zone long after that.
    {Oban.Plugins.Cron, crontab: [{"17 * * * *", PiFi.Device.Upgrade.Check}]},
    # **A prune of 10,000 rows in one statement holds the write lock for as long as it
    # takes**, and a read of a library writes one artwork job for each container, so the
    # table reaches that size on a real library. Everything else that writes waits behind
    # it, and the audio is one of those things. 500 at a time costs more statements and
    # holds the lock for a moment each.
    {Oban.Plugins.Pruner, max_age: 604_800, limit: 500}
  ],
  # **A device that stops in the middle of a job leaves that job `executing` for ever.**
  # This device stops often: it goes into standby, a person takes the power away, and a
  # new firmware restarts it. Nothing moves such a job back, and a scheduled action is
  # unique, so one job that no process runs stops every later one. A read of a Jellyfin
  # library stopped that way on 2026-09-03, and `Read the library now` then did nothing
  # at all, for the schedule as well as for the person who pressed it.
  #
  # **Two hours, because a real read takes a long time.** The two reads of a library of
  # 53,105 items that finished took 515 s and 2096 s, and a library grows. This plugin
  # reads the clock and nothing else, so a shorter time would move a job that still
  # runs, and the device would read the whole library twice and write the card twice.
  lifeline: [rescue_after: {2, :hours}]

# **Ecto builds this prefix from the name of the repo module**, which underscores to
# `:pi_fi`, and every other event of this firmware carries `:pifi`. A second spelling of
# the name of the product costs a reader a search, and it costs a handler that listens
# for the wrong one its measurement. `AshSqlite.Repo` gives `Ecto.Repo` the OTP
# application and the adapter and no other option, so this cannot sit beside `use`.
# **`busy_timeout` does not cover a transaction that reads and then writes**, and that
# is the one this device kept losing. SQLite begins a `DEFERRED` transaction by default
# and takes no lock until the first statement needs one, so a transaction that reads,
# and then tries to write after another connection has committed, cannot keep the
# snapshot it read. SQLite answers `SQLITE_BUSY` for that at once and **it does not call
# the busy handler**, so the 10 second timeout of `config/target.exs` never applies and
# the caller sees `Database busy` with no wait at all.
#
# `Oban.Pruner` is exactly that shape: it reads the jobs to remove and then deletes
# them. It stopped on a board with a library sync running, and `PiFi.Cache.Entry` threw
# away an episode that had already arrived for the same reason.
#
# `IMMEDIATE` takes the write lock at `BEGIN`, which is where the busy handler does run,
# so a writer waits its turn rather than failing. The cost is that a transaction that
# only reads still queues behind a writer, and on this device a transaction is almost
# always a write.
# **`busy_timeout` belongs here and not only on the device.** It used to sit in
# `config/target.exs` alone, so a laptop ran on the 2 seconds that exqlite gives by
# default. With the mode above every transaction waits for the write lock, and two
# seconds of waiting is not much when a library sync, `Oban.Stager` and `Oban.Met` are
# all writing: the three of them fell over with `database is locked` on `BEGIN IMMEDIATE
# TRANSACTION`, which is the lock being asked for and refused.
#
# **10 seconds, and not more.** An Ecto call gives up at 15 seconds by default, and a
# handler that waited longer than its caller would turn one error into another.
#
# exqlite installs its own busy handler through a NIF rather than `PRAGMA busy_timeout`,
# because the pragma calls `sqlite3_busy_timeout()` and that destroys the custom
# handler. So `PRAGMA busy_timeout` reads 0 on a live connection and that is correct —
# do not read it and conclude the setting is being ignored.
config :pifi, PiFi.Repo,
  telemetry_prefix: [:pifi, :repo],
  default_transaction_mode: :immediate,
  busy_timeout: 10_000

# **The forge is the whole of the release channel.** A tag of the form `v1.2.3` builds a
# production firmware for each target and attaches it to a release, so a device needs no
# service of its own to learn that a version landed. See `PiFi.Device.Upgrade`.
#
# `download_path` is the writable partition, which mounts at `/root` on a target.
# `config/host.exs` names somewhere that a person may write instead.
config :pifi, PiFi.Device.Upgrade,
  download_path: "/root",
  releases_url: "https://harton.dev/api/v1/repos/mypihifiguy/pifi/releases/latest"

config :pifi,
  ecto_repos: [PiFi.Repo],
  ash_domains: [
    PiFi.Cache,
    PiFi.Device,
    PiFi.Jellyfin,
    PiFi.Playback,
    PiFi.Plex,
    PiFi.Podcast,
    PiFi.Radio,
    PiFi.Settings
  ]

# These enable behaviors that will become the default in the next major
# version of Ash. Setting them now opts your application into the new
# behavior and ensures a seamless upgrade. See the backwards compatibility
# guide for an explanation of each setting:
# https://hexdocs.pm/ash/backwards-compatibility-config.html
config :ash,
  allow_forbidden_field_for_relationships_by_default: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  many_to_many_destroy_destination_on_match?: true

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [section_order: [:resources, :policies, :authorization, :domain, :execution]]
  ]

config :tailwind,
  version: "4.1.12",
  pifi: [
    args: ~w(
    --input=assets/css/app.css
    --output=priv/static/assets/css/app.css
  ),
    cd: Path.expand("..", __DIR__)
  ]

config :esbuild,
  version: "0.25.4",
  pifi: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :phoenix, json_library: Jason

# Every collection of the web interface draws with the faceplate style. See
# `PiFiWeb.CinderTheme`.
config :cinder, default_theme: PiFiWeb.CinderTheme

config :logger,
  default_formatter: [format: "$time $metadata[$level] $message\n", metadata: [:request_id]]

config :pifi,
       PiFiWeb.Endpoint,
       url: [host: "localhost"],
       adapter: Bandit.PhoenixAdapter,
       render_errors: [
         formats: [json: PiFiWeb.ErrorJSON],
         layout: false
       ],
       pubsub_server: PiFi.PubSub

# The LiveView signing salt is absent here on purpose. A target makes one for
# itself and keeps it under `/root`, so two devices hold two salts. See
# `PiFi.DeviceSecrets`. `config/host.exs` holds a fixed one, so a session in
# local development continues after a restart.

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

# Customize non-Elixir parts of the firmware. See
# https://nerves.hexdocs.pm/advanced-configuration.html for details.

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1787022821"

# A screen of this device opens no window and drives no display: it renders to
# pixels and writes them to a panel over SPI. See `PiFi.Screen.Renderer`.
#
# **An empty list is the raster NIF, and Emerge 0.4 publishes one.** 0.3 published a
# NIF for each of three backends and none for no backend, so this project took
# `[:wayland]`, the smallest of the three, and called nothing in it. That variant
# names `libxkbcommon`, and the raster NIF needs no library of a display at all.
#
# **The host needs the same line as the target.** `EmergeSkia.BuildConfig` chooses
# `[:drm]` by itself, that variant names `libgbm`, and a build machine without Mesa
# cannot open the NIF. The tests of each screen then stop with `EmergeSkia.Native is
# not available`.
config :emerge, compiled_backends: []

import_config "#{config_env()}.exs"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
