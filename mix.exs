defmodule MyHiFi.MixProject do
  use Mix.Project

  @app :my_hi_fi
  @version "0.1.0"
  @all_targets [
    :bbb,
    :mangopi_mq_pro,
    :qemu_aarch64,
    :rpi,
    :rpi0,
    :rpi0_2,
    :rpi2,
    :rpi3,
    :rpi4,
    :rpi5,
    :x86_64
  ]

  def project do
    [
      aliases: aliases(),
      app: @app,
      archives: [nerves_bootstrap: "~> 1.17"],
      consolidate_protocols: Mix.env() != :dev,
      deps: deps(),
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      listeners: listeners(Mix.target(), Mix.env()),
      releases: [{@app, release()}],
      start_permanent: Mix.env() == :prod,
      version: @version,
      usage_rules: usage_rules()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :runtime_tools, :os_mon],
      mod: {MyHiFi.Application, []}
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:oban, "~> 2.0"},
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:ash_state_machine, "~> 0.2"},
      {:oban_web, "~> 2.0"},
      {:ash_oban, "~> 0.8"},
      {:ash_sqlite, "~> 0.2"},
      {:ash, "~> 3.0"},
      # Dependencies for all targets
      {:bandit, "~> 1.5"},
      {:gettext, "~> 0.26"},
      {:heroicons,
       [
         github: "tailwindlabs/heroicons",
         tag: "v2.2.0",
         sparse: "optimized",
         app: false,
         compile: false,
         depth: 1
       ]},
      {:nerves, "~> 1.13", runtime: false},
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:phoenix_live_view, "~> 1.0"},
      {:ring_logger, "~> 0.11.0"},
      {:shoehorn, "~> 0.9.1"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:toolshed, "~> 0.5.0"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.12"},

      # Dependencies for all targets except :host
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},

      # Dependencies for specific targets
      # NOTE: It's generally low risk and recommended to follow minor version
      # bumps to Nerves systems. Since these include Linux kernel and Erlang
      # version updates, please review their release notes in case
      # changes to your application are needed.
      {:nerves_system_bbb, "~> 2.19", runtime: false, targets: :bbb},
      {:nerves_system_mangopi_mq_pro, "~> 0.6", runtime: false, targets: :mangopi_mq_pro},
      {:nerves_system_qemu_aarch64, "~> 0.1", runtime: false, targets: :qemu_aarch64},
      {:nerves_system_rpi, "~> 2.0", runtime: false, targets: :rpi},
      {:nerves_system_rpi0, "~> 2.0", runtime: false, targets: :rpi0},
      {:nerves_system_rpi0_2, "~> 2.0", runtime: false, targets: :rpi0_2},
      {:nerves_system_rpi2, "~> 2.0", runtime: false, targets: :rpi2},
      {:nerves_system_rpi3, "~> 2.0", runtime: false, targets: :rpi3},
      {:nerves_system_rpi4, "~> 2.0", runtime: false, targets: :rpi4},
      {:nerves_system_rpi5, "~> 2.0", runtime: false, targets: :rpi5},
      {:nerves_system_x86_64, "~> 1.24", runtime: false, targets: :x86_64},

      # Dev/test deps.
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev, target: :host},
      {:phx_install, "~> 0.1", only: [:dev], target: :host},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev, target: :host}
    ]
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://nerves-pack.hexdocs.pm/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  # Uncomment the following line if using Phoenix > 1.8.
  # defp listeners(:host, :dev), do: [Phoenix.CodeReloader]
  defp listeners(_, _), do: []

  defp aliases() do
    [
      "assets.setup": ["esbuild.install --if-missing", "tailwind.install --if-missing"],
      "assets.build": ["compile", "esbuild my_hi_fi", "tailwind my_hi_fi"],
      "assets.deploy": ["esbuild my_hi_fi --minify", "tailwind my_hi_fi --minify", "phx.digest"],
      setup: ["deps.get", "assets.setup", "assets.build"],
      test: ["ash.setup --quiet", "test"]
    ]
  end

  defp elixirc_paths(:test),
    do: elixirc_paths(:dev) ++ ["test/support"]

  defp elixirc_paths(_),
    do: ["lib"]

  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: ["usage_rules:all"],
      skills: [
        location: ".agents/skills",
        builds: [
          "ash-framework": [
            description: "Use this skill for working with the Ash Framework or any of its extensions. Always consult this when making any domain changes, features or fixes.",
            usage_rules: [:ash, ~r/^ash_/, :reactor, ~r/^reactor_/]
          ],
          "phoenix-framework": [
            description: "Use this skill working with Phoenix Framework. Consult this when working with the web layer, controllers, views, liveviews etc.",
            usage_rules: [:phoenix, ~r/^phoenix_/]
          ]
        ]
      ]
    ]
  end
end
