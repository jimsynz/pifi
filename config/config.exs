# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

config :ash_oban, pro?: false
config :ash, default_string_length_count: :codepoints

config :my_hi_fi, Oban,
  engine: Oban.Engines.Lite,
  notifier: Oban.Notifiers.PG,
  queues: [default: 10],
  repo: MyHiFi.Repo,
  # A job that finished stays in the table until something removes it, and this device
  # runs for years on an SD card. A week is long enough to read what happened and short
  # enough that the table never grows.
  plugins: [{Oban.Plugins.Cron, []}, {Oban.Plugins.Pruner, max_age: 604_800}],
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

config :my_hi_fi,
  ecto_repos: [MyHiFi.Repo],
  ash_domains: [
    MyHiFi.Cache,
    MyHiFi.Device,
    MyHiFi.Jellyfin,
    MyHiFi.Playback,
    MyHiFi.Podcast,
    MyHiFi.Radio,
    MyHiFi.Settings
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
  my_hi_fi: [
    args: ~w(
    --input=assets/css/app.css
    --output=priv/static/assets/css/app.css
  ),
    cd: Path.expand("..", __DIR__)
  ]

config :esbuild,
  version: "0.25.4",
  my_hi_fi: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :phoenix, json_library: Jason

# Every collection of the web interface draws with the faceplate style. See
# `MyHiFiWeb.CinderTheme`.
config :cinder, default_theme: MyHiFiWeb.CinderTheme

config :logger,
  default_formatter: [format: "$time $metadata[$level] $message\n", metadata: [:request_id]]

config :my_hi_fi,
       MyHiFiWeb.Endpoint,
       url: [host: "localhost"],
       adapter: Bandit.PhoenixAdapter,
       render_errors: [
         formats: [json: MyHiFiWeb.ErrorJSON],
         layout: false
       ],
       pubsub_server: MyHiFi.PubSub

# The LiveView signing salt is absent here on purpose. A target makes one for
# itself and keeps it under `/root`, so two devices hold two salts. See
# `MyHiFi.DeviceSecrets`. `config/host.exs` holds a fixed one, so a session in
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
# pixels and writes them to a panel over SPI. See `MyHiFi.Screen.Renderer`.
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
