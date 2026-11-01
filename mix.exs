defmodule PiFi.MixProject do
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
    pifi_rpi0_2: %{
      "TARGET_ARCH" => "aarch64",
      # `rustler_precompiled` reads these four as well, and it then looks for a NIF
      # whose name holds the vendor. `emerge` publishes
      # `aarch64-unknown-linux-gnu` and no `aarch64-nerves-linux-gnu`, so
      # `"nerves"` here makes it compile Skia from source. Its documentation asks
      # for `"unknown"` on Nerves. Bundlex puts the value in a map and reads it
      # nowhere else, and `Membrane.PrecompiledDependencyProvider` matches the
      # architecture, the operating system and the ABI, and never the vendor.
      "TARGET_VENDOR" => "unknown",
      "TARGET_OS" => "linux",
      "TARGET_ABI" => "gnu"
    }
  }

  case Map.fetch(@bundlex_targets, Mix.target()) do
    {:ok, env} -> System.put_env(env)
    :error -> :ok
  end

  @app :pifi
  @version "0.1.0"
  # This product ships one board, and the list holds that board alone. The
  # template names eleven stock targets, and no build of this firmware ever used
  # one: the DAC needs a USB host stack and a USB audio driver that no stock
  # system holds, and the screen needs the `libxkbcommon` that the custom system
  # carries for the Emerge NIF. Each extra target also cost a dependency bump
  # that no person read. `x86_64` is absent for a reason of its own: that system
  # uses musl, and libvorbis does not build against musl, so `nbpr_vorbis_tools`
  # cannot serve it.
  @all_targets [:pifi_rpi0_2]

  def project do
    [
      aliases: aliases(),
      app: @app,
      archives: [nerves_bootstrap: "~> 1.17"],
      # **The only native code this project builds is the ALAC decoder.** Bundlex
      # already cross-compiles the Membrane NIFs for this target, so it is the
      # toolchain the project has rather than a new one. See `bundlex.exs`.
      compilers: [:bundlex] ++ Mix.compilers(),
      consolidate_protocols: Mix.env() != :dev,
      deps: deps(),
      elixir: "~> 1.20",
      elixirc_options: elixirc_options(Mix.target()),
      elixirc_paths: elixirc_paths(Mix.env()),
      listeners: listeners(Mix.target(), Mix.env()),
      releases: [{@app, release()}],
      start_permanent: Mix.env() == :prod,
      version: @version,
      usage_rules: usage_rules()
    ]
  end

  defp elixirc_options(:host) do
    [
      no_warn_undefined: [
        NBPR.Bluez5Utils.Bluetoothd,
        NBPR.BluezAlsa.Bluealsad,
        NBPR.Dbus.DbusDaemon,
        NBPR.Librespot.Librespot
      ]
    ]
  end

  defp elixirc_options(_target), do: []

  def application do
    [
      extra_applications: [:logger, :runtime_tools, :os_mon],
      mod: {PiFi.Application, []}
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  defp deps do
    [
      {:nbpr, "~> 0.3"},
      {:nbpr_flac, "~> 1.5", organization: "nbpr", targets: @all_targets},
      {:nbpr_vorbis_tools, "~> 1.4", organization: "nbpr", targets: @all_targets},
      {:nbpr_libvips, "~> 8.18", organization: "nbpr", targets: @all_targets},
      {:nbpr_librespot, "~> 0.8", organization: "nbpr", targets: @all_targets},
      {:dbus, "~> 0.8"},
      {:nbpr_dbus, "~> 1.14", organization: "nbpr", targets: @all_targets},
      {:nbpr_bluez5_utils, "~> 5.79", organization: "nbpr", targets: @all_targets},
      {:nbpr_sbc, "~> 2.1", organization: "nbpr", targets: @all_targets},
      {:nbpr_bluez_alsa, "~> 4.3", organization: "nbpr", targets: @all_targets},
      {:ash, "~> 3.0"},
      {:ash_oban, "~> 0.9"},
      {:ash_sqlite, "~> 0.2"},
      {:ash_storage,
       github: "ash-project/ash_storage",
       ref: "dc17feb6a894d27c180840f83288a70496a90d2a",
       override: true},
      {:ash_state_machine, "~> 0.2"},
      {:bandit, "~> 1.5"},
      {:bundlex, "~> 1.5"},
      {:thousand_island, "~> 1.5"},
      {:cinder, "~> 0.18"},
      {:circuits_gpio, "~> 2.1"},
      {:circuits_i2c, "~> 2.1"},
      {:foc_peripheral,
       git: "https://harton.dev/mypihifiguy/foc_peripheral.git", branch: "main", sparse: "host"},
      {:espex, "~> 0.9"},
      {:homex, github: "jimsynz/homex", branch: "feat/media-player-entity"},
      {:muontrap, "~> 2.0", override: true},
      {:circuits_spi, "~> 2.1"},
      {:decimal, "~> 3.0", override: true},
      {:emerge, "~> 0.5"},
      {:max1704x, "~> 0.1"},
      {:membrane_aac_fdk_plugin, "~> 0.19"},
      {:membrane_aac_plugin, "~> 0.19"},
      {:membrane_core, "~> 1.0"},
      {:membrane_hls_plugin, "~> 3.0"},
      {:membrane_mp3_mad_plugin, "~> 0.18"},
      {:membrane_mpeg_ts_plugin, "~> 2.4"},
      {:gettext, "~> 1.0"},
      {:phosphor_icons,
       [
         github: "phosphor-icons/core",
         tag: "v2.0.8",
         sparse: "assets/bold",
         app: false,
         compile: false,
         depth: 1
       ]},
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
      {:req, "~> 0.7"},
      {:ring_logger, "~> 0.11"},
      {:saxy, "~> 1.6"},
      {:tz, "~> 0.28"},
      {:shoehorn, "~> 0.9.1"},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:toolshed, "~> 0.5.0"},
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:nerves_runtime, "~> 0.13.12"},

      # Target deps
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},
      {:nerves_time, "~> 0.4", targets: @all_targets},
      {:vintage_net, "~> 0.13", targets: @all_targets},
      {:vintage_net_wizard,
       github: "nerves-networking/vintage_net_wizard",
       ref: "6df7ab2a423e95e0a220861e13769574e10e2a68",
       targets: @all_targets},
      {:nerves_system_pifi_rpi0_2,
       git: "https://harton.dev/mypihifiguy/nerves_system_pifi_rpi0_2.git",
       tag: "v0.2.1",
       runtime: false,
       targets: :pifi_rpi0_2,
       nerves: [compile: true]},

      # Dev/test deps.
      {:credo, "~> 1.7", runtime: false, only: [:dev, :test], target: :host},
      {:lazy_html, ">= 0.1.0", only: :test, target: :host},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:ex_check_ng, "~> 1.0.0-rc.2", only: [:dev, :test], targets: :host},
      {:ex_doc, "~> 0.40", only: [:dev, :test], targets: :host},
      {:phx_install, "~> 0.1", only: [:dev], targets: :host},
      {:sobelow, "~> 0.16", only: [:dev, :test], targets: :host},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev}
    ]
  end

  def release do
    [
      overwrite: true,
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [
        &Nerves.Release.init/1,
        &stamp_environment/1,
        &prune_foreign_precompiled/1,
        &drop_native_objects/1,
        :assemble
      ],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  defp stamp_environment(release) do
    System.put_env("NERVES_FW_MISC", "env=#{Mix.env()}")

    unless Mix.env() == :prod or Mix.target() == :host do
      Mix.shell().info([
        :yellow,
        "\nThis is a #{Mix.env()} firmware for #{Mix.target()}, and it holds an SSH ",
        "daemon.\nBuild it with MIX_ENV=prod for a device that a hand cannot reach.\n",
        :reset
      ])
    end

    release
  end

  defp listeners(:host, :dev), do: [Phoenix.CodeReloader]
  defp listeners(_, _), do: []

  defp vendored_priv(_args) do
    source = Path.expand("deps/nbpr_librespot/priv")
    target = Path.join([Mix.Project.build_path(), "lib", "nbpr_librespot", "priv"])

    if File.dir?(source) and not File.dir?(Path.join(target, "buildroot")) do
      File.rm_rf!(target)
      File.mkdir_p!(Path.dirname(target))
      File.ln_s!(source, target)
    end

    :ok
  end

  defp aliases() do
    [
      "assets.setup": ["esbuild.install --if-missing", "tailwind.install --if-missing"],
      "assets.build": ["compile", "esbuild pifi", "tailwind pifi"],
      "assets.deploy": ["esbuild pifi --minify", "tailwind pifi --minify", "phx.digest"],
      setup: ["deps.get", "assets.setup", "assets.build"],
      test: ["ash.setup --quiet", "test"],
      credo: ["credo --strict"],
      firmware: ["assets.deploy", &vendored_priv/1, "nbpr.fetch", "firmware"]
    ]
  end

  defp prune_foreign_precompiled(release) do
    with {:ok, %{"TARGET_ARCH" => arch}} <- Map.fetch(@bundlex_targets, Mix.target()),
         {:ok, keep} <- precompiled_name(arch) do
      build = Mix.Project.build_path()

      materialise_symlink(Path.join([build, "lib", "bundlex", "priv"]))

      [
        Path.join([build, "lib", "bundlex", "priv", "shared", "precompiled", "*"]),
        Path.join([build, "lib", "*", "priv", "bundlex", "nif", "*"])
      ]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.filter(&String.ends_with?(&1, ".tar.gz"))
      |> Enum.reject(&String.contains?(Path.basename(&1), keep))
      |> Enum.each(&File.rm_rf!/1)
    end

    prune_foreign_rustler(release)
  end

  defp drop_native_objects(release) do
    [Mix.Project.build_path(), "lib", "#{@app}", "priv", "bundlex", "*", "*_obj"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.each(&File.rm_rf!/1)

    release
  end

  defp prune_foreign_rustler(release) do
    with {:ok, env} <- Map.fetch(@bundlex_targets, Mix.target()) do
      keep = triple(env)
      build = Mix.Project.build_path()

      build
      |> Path.join("lib/*/priv")
      |> Path.wildcard()
      |> Enum.filter(&File.dir?(Path.join(&1, "native")))
      |> Enum.each(&materialise_symlink/1)

      build
      |> Path.join("lib/*/priv/native/*")
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(Path.basename(&1), keep))
      |> Enum.each(&File.rm_rf!/1)
    end

    release
  end

  defp triple(%{
         "TARGET_ARCH" => arch,
         "TARGET_VENDOR" => vendor,
         "TARGET_OS" => os,
         "TARGET_ABI" => abi
       }),
       do: "#{arch}-#{vendor}-#{os}-#{abi}"

  defp materialise_symlink(path) do
    case File.read_link(path) do
      {:ok, target} ->
        real = Path.expand(target, Path.dirname(path))
        File.rm!(path)
        File.cp_r!(real, path)

      {:error, _reason} ->
        :ok
    end
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
