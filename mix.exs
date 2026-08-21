defmodule MyHiFi.MixProject do
  use Mix.Project

  # Bundlex reads the build target from these four variables when `CROSSCOMPILE`
  # has a value. Nerves gives a value to `CROSSCOMPILE` and to
  # `REBAR_TARGET_ARCH`, and it gives no value to these four. Each one then
  # becomes "unknown", and `Membrane.PrecompiledDependencyProvider` gives `nil`
  # for each precompiled library. Bundlex then uses `pkg-config` against a
  # sysroot that holds no such library, and the build stops with an error.
  #
  # Bundlex reads the variables when Bundlex itself compiles, so they must have a
  # value before the dependencies compile. `mix.exs` runs first in each mix task.
  # Add an entry for each new target.
  @bundlex_targets %{
    myhifi_rpi0_2: %{
      "TARGET_ARCH" => "aarch64",
      "TARGET_VENDOR" => "nerves",
      "TARGET_OS" => "linux",
      "TARGET_ABI" => "gnu"
    }
  }

  case Map.fetch(@bundlex_targets, Mix.target()) do
    {:ok, env} -> System.put_env(env)
    :error -> :ok
  end

  @app :my_hi_fi
  @version "0.1.0"
  @all_targets [
    :bbb,
    :mangopi_mq_pro,
    :qemu_aarch64,
    :rpi,
    :rpi0,
    :myhifi_rpi0_2,
    :rpi2,
    :rpi3,
    :rpi4,
    :rpi5,
    :trellis,
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
      # Dependencies for all targets
      {:ash, "~> 3.0"},
      {:ash_oban, "~> 0.8"},
      {:ash_sqlite, "~> 0.2"},
      {:ash_state_machine, "~> 0.2"},
      {:bandit, "~> 1.5"},
      # `membrane_core` needs `ratio`, and `ratio` names
      # `decimal ~> 1.6 or ~> 2.0`. `ecto_sqlite3` needs `decimal ~> 3.0`, so the
      # two do not agree.
      #
      # The requirement of `ratio` is out of date. `decimal` is optional there,
      # and `Ratio.DecimalConversion` reads the `coef`, `exp` and `sign` fields of
      # the struct and calls no function of the library. Version 3 keeps those
      # three fields, and each of its breaking changes is in the context defaults,
      # in `parse`, in `cast`, or in `to_string`. This override is therefore safe.
      #
      # Remove it when a `ratio` release accepts version 3.
      {:decimal, "~> 3.0", override: true},
      {:membrane_aac_fdk_plugin, "~> 0.18"},
      {:membrane_aac_plugin, "~> 0.19"},
      {:membrane_core, "~> 1.0"},
      {:membrane_mp3_mad_plugin, "~> 0.18"},
      {:gettext, "~> 1.0"},
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
      {:oban, "~> 2.0"},
      {:oban_web, "~> 2.0"},
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:phoenix_live_view, "~> 1.0"},
      # The sync job fetches the station list. `req` already arrives through a
      # dependency of Membrane, and this line makes the reliance explicit, so a
      # change there cannot take it away.
      {:req, "~> 0.5"},
      {:ring_logger, "~> 0.11.0"},
      {:shoehorn, "~> 0.9.1"},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:toolshed, "~> 0.5.0"},
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:nerves_runtime, "~> 0.13.12"},
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},
      # Release 0.4.17 is from 2024-06-05, and it needs plug_cowboy. Each cowlib
      # release from 2.9.0 to 2.19.0 holds two advisories, and no release fixes
      # them. The main branch uses Bandit instead, and Phoenix already gives us
      # Bandit, so cowboy and cowlib leave the dependency tree.
      {:vintage_net_wizard,
       github: "nerves-networking/vintage_net_wizard", ref: "c11eabea849e", targets: @all_targets},

      # Targets
      {:nerves_system_bbb, "~> 2.19", runtime: false, targets: :bbb},
      {:nerves_system_mangopi_mq_pro, "~> 0.6", runtime: false, targets: :mangopi_mq_pro},
      {:nerves_system_qemu_aarch64, "~> 0.1", runtime: false, targets: :qemu_aarch64},
      {:nerves_system_rpi, "~> 2.0", runtime: false, targets: :rpi},
      {:nerves_system_rpi0, "~> 2.0", runtime: false, targets: :rpi0},
      # The stock rpi0_2 system holds no USB host stack and no USB audio driver,
      # so a USB DAC cannot work on it. It also gives 192 MB to the GPU and
      # reserves 128 MB of CMA, and this device drives no display over HDMI. See
      # the README of the system.
      {:nerves_system_myhifi_rpi0_2,
       git: "https://harton.dev/mypihifiguy/nerves_system_myhifi_rpi0_2.git",
       tag: "v0.1.0",
       runtime: false,
       targets: :myhifi_rpi0_2},
      {:nerves_system_rpi2, "~> 2.0", runtime: false, targets: :rpi2},
      {:nerves_system_rpi3, "~> 2.0", runtime: false, targets: :rpi3},
      {:nerves_system_rpi4, "~> 2.0", runtime: false, targets: :rpi4},
      {:nerves_system_rpi5, "~> 2.0", runtime: false, targets: :rpi5},
      {:nerves_system_trellis, "~> 0.4", runtime: false, targets: :trellis},
      {:nerves_system_x86_64, "~> 1.24", runtime: false, targets: :x86_64},

      # Dev/test deps.
      {:credo, "~> 1.7", runtime: false, only: [:dev, :test], target: :host},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev, target: :host},
      {:ex_check_ng, "~> 1.0.0-rc.2", only: [:dev, :test], target: :host},
      {:ex_doc, "~> 0.40", only: [:dev, :test], target: :host},
      {:phx_install, "~> 0.1", only: [:dev], target: :host},
      {:sobelow, "~> 0.15", only: [:dev, :test], target: :host},
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
      steps: [&Nerves.Release.init/1, &prune_foreign_precompiled/1, :assemble],
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
      test: ["ash.setup --quiet", "test"],
      credo: ["credo --strict"]
    ]
  end

  # Bundlex keeps each precompiled library in two places, and each place holds a
  # directory named after the URL of the archive.
  #
  # `deps/bundlex/priv/shared/precompiled` is the cache, and every target shares
  # it, because `_build/<target>/lib/bundlex/priv` is a symbolic link to it. Each
  # plugin then gets a copy under
  # `_build/<target>/lib/<plugin>/priv/bundlex/nif`, and the copy happens when the
  # plugin compiles.
  #
  # A build for the host therefore leaves an x86 library in the cache, a later
  # build for a target copies it beside the NIF, and the Nerves scrub step stops
  # with "Unexpected executable format".
  #
  # This step runs before the release assembles, and after each plugin compiles.
  # It removes from both places each library that does not match the architecture
  # of this build. A later build for another architecture gets its own library
  # again, because Bundlex downloads what it does not find.
  defp prune_foreign_precompiled(release) do
    with {:ok, %{"TARGET_ARCH" => arch}} <- Map.fetch(@bundlex_targets, Mix.target()),
         {:ok, keep} <- precompiled_name(arch) do
      [
        Path.join(["deps", "bundlex", "priv", "shared", "precompiled", "*"]),
        Path.join([Mix.Project.build_path(), "lib", "*", "priv", "bundlex", "nif", "*"])
      ]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.filter(&(File.dir?(&1) and String.ends_with?(&1, ".tar.gz")))
      |> Enum.reject(&String.contains?(Path.basename(&1), keep))
      |> Enum.each(&File.rm_rf!/1)
    end

    release
  end

  defp precompiled_name("aarch64"), do: {:ok, "linux_arm"}
  defp precompiled_name("x86_64"), do: {:ok, "linux_x86"}
  defp precompiled_name(_other), do: :error

  defp elixirc_paths(:test),
    do: elixirc_paths(:dev) ++ ["test/support"]

  defp elixirc_paths(_),
    do: ["lib"]

  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [{:usage_rules, link: :markdown}],
      skills: [
        location: ".agents/skills",
        build: [
          "ash-framework": [
            description:
              "Use this skill for working with the Ash Framework or any of its extensions. Always consult this when making any domain changes, features or fixes.",
            usage_rules: [:ash, ~r/^ash_/, :reactor, ~r/^reactor_/]
          ],
          "phoenix-framework": [
            description:
              "Use this skill working with Phoenix Framework. Consult this when working with the web layer, controllers, views, liveviews etc.",
            usage_rules: [:phoenix, ~r/^phoenix_/]
          ],
          "ex-check": [
            description: "Use this skill for working with `mix check`",
            usage_rules: [:ex_check_ng]
          ]
        ]
      ]
    ]
  end
end
