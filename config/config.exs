import Config

config :ash_oban, pro?: false
config :ash, default_string_length_count: :codepoints

config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :tz,
  reject_periods_before_year: 2020,
  build_dst_periods_until_year: 2040

config :pifi, Oban,
  engine: Oban.Engines.Lite,
  notifier: Oban.Notifiers.PG,
  queues: [default: 10, artwork: 1],
  repo: PiFi.Repo,
  plugins: [
    {Oban.Plugins.Cron, crontab: [{"17 * * * *", PiFi.Device.Upgrade.Check}]},
    {Oban.Plugins.Pruner, max_age: 604_800, limit: 500}
  ],
  lifeline: [rescue_after: {2, :hours}]

config :pifi, PiFi.Repo,
  telemetry_prefix: [:pifi, :repo],
  default_transaction_mode: :immediate,
  busy_timeout: 10_000

config :pifi, PiFi.Device.Upgrade,
  download_path: "/root",
  releases_url: "https://harton.dev/api/v1/repos/mypihifiguy/pifi/releases/latest"

config :pifi,
  ecto_repos: [PiFi.Repo],
  ash_domains: [
    PiFi.AirPlay,
    PiFi.Cache,
    PiFi.Device,
    PiFi.Jellyfin,
    PiFi.Playback,
    PiFi.Plex,
    PiFi.Podcast,
    PiFi.Radio,
    PiFi.Settings
  ]

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

Application.start(:nerves_bootstrap)

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"
config :nerves, source_date_epoch: "1787022821"
config :emerge, compiled_backends: []

import_config "#{config_env()}.exs"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
