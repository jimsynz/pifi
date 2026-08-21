# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

config :ash_oban, pro?: false

config :my_hi_fi, Oban,
  engine: Oban.Engines.Lite,
  notifier: Oban.Notifiers.PG,
  queues: [default: 10],
  repo: MyHiFi.Repo,
  plugins: [{Oban.Plugins.Cron, []}]

config :my_hi_fi,
  ecto_repos: [MyHiFi.Repo],
  ash_domains: [MyHiFi.Device, MyHiFi.Playback, MyHiFi.Radio, MyHiFi.Settings]

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
       pubsub_server: MyHiFi.PubSub,
       live_view: [signing_salt: "EhXdl2qH"]

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

# Customize non-Elixir parts of the firmware. See
# https://nerves.hexdocs.pm/advanced-configuration.html for details.

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1787022821"

import_config "#{config_env()}.exs"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
