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

  @app :my_hi_fi
  @version "0.1.0"
  @all_targets [
    # `x86_64` is absent, and its Nerves system is gone with it. That system uses
    # musl, and libvorbis does not build against musl, so `nbpr_vorbis_tools`
    # cannot serve that target. This firmware runs on `myhifi_rpi0_2`, and no
    # x86_64 build ever ran.
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
    :trellis
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
      # The EEF OSV record includes Decimal 3 in error. The advisory affects versions
      # before 3.0.0. The `decimal` override below must stay while this exclusion exists.
      hex: [ignore_advisories: ["CVE-2026-32686"]],
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
      # 0.3.0 adds `:unsupported_libc` to the schema of `NBPR.BrPackage`, and
      # `nbpr_vorbis_tools` needs that option. 0.2.1 refused it and stopped the
      # build.
      {:nbpr, "~> 0.3"},
      # Membrane holds no decoder for Vorbis or for FLAC, so
      # `MyHiFi.Player.PortDecoder` drives a program instead. NBPR gives the
      # program for the target, and it ships a binary and no header file, which is
      # all that a port needs. See section 6.1 of the specification.
      #
      # These are target only. A host holds its own `flac` and `oggdec`, and that
      # is how the pipeline was read end to end before the packages existed.
      #
      # `nbpr_flac` brings `nbpr_libogg`, and that is what makes `flac --ogg` work.
      # Every FLAC station of New Zealand sends FLAC inside an Ogg container, so
      # this firmware needs that option and nothing else would serve.
      {:nbpr_flac, "~> 1.5", organization: "nbpr", targets: @all_targets},
      {:nbpr_vorbis_tools, "~> 1.4", organization: "nbpr", targets: @all_targets},
      {:nbpr_libvips, "~> 8.18", organization: "nbpr", targets: @all_targets},
      # Dependencies for all targets
      {:ash, "~> 3.0"},
      {:ash_oban, "~> 0.8"},
      {:ash_sqlite, "~> 0.2"},
      # `MyHiFi.Cache` models the cache on disk with this. It is not on Hex, and its
      # author says that the API iterates, so this names a reference and pins it in
      # the way that `vintage_net_wizard` is pinned. A new reference therefore needs a
      # read of what changed.
      {:ash_storage,
       github: "ash-project/ash_storage",
       ref: "aa5766a4594ebdc4a5dd6fd41993e6707ffd4db2",
       override: true},
      {:ash_state_machine, "~> 0.2"},
      {:bandit, "~> 1.5"},
      # The browse page gives Cinder a query, and Cinder holds the loading state, the
      # sort, the page controls and the URL state. It is pure Elixir, and so is
      # `ash_phoenix`, which it needs.
      {:cinder, "~> 0.16"},
      # `MyHiFi.Peripheral.PiTft` owns the SPI bus of the screen and the data line
      # that goes with it. `MyHiFi.Peripheral.Battery` owns the I2C bus of the fuel
      # gauge, and `max1704x` and `wafer` both name `circuits_i2c` as optional, so this
      # is the project that must ask for it.
      {:circuits_gpio, "~> 2.1"},
      {:circuits_i2c, "~> 2.1"},
      {:circuits_spi, "~> 2.1"},
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
      # `MyHiFi.Peripheral.PiTft` draws the device screen with this. It holds a
      # Rust NIF that lays a tree out and draws it with Skia, and the firmware
      # calls the raster part of it. That part opens no window and it drives no
      # display: it gives the pixels back, and the peripheral writes them to the
      # screen over SPI.
      #
      # `config/target.exs` names the backend, because `EmergeSkia.BuildConfig`
      # sees `MIX_TARGET` and chooses the DRM one by itself, and it holds the reason
      # that the choice is what it is.
      {:emerge, "~> 0.3"},
      # The fuel gauge of the UPS-Lite pHAT. It reads the charge of the cell over I2C,
      # and it holds no native code of its own: `wafer` is the layer that talks to
      # `circuits_i2c`. See `MyHiFi.Peripheral.Battery`.
      {:max1704x, "~> 0.1.1"},
      {:membrane_aac_fdk_plugin, "~> 0.18"},
      {:membrane_aac_plugin, "~> 0.19"},
      {:membrane_core, "~> 1.0"},
      {:membrane_hls_plugin, "~> 3.0"},
      {:membrane_mp3_mad_plugin, "~> 0.18"},
      {:membrane_mpeg_ts_plugin, "~> 2.4"},
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
      # `MyHiFi.Podcast.Feed.Parser` reads a podcast feed with this. It is pure
      # Elixir and it holds no dependency of its own, so it needs nothing from the
      # Nerves system. `Saxy.Partial` takes one chunk at a time, so a 13 MB feed
      # never arrives in memory as one binary.
      {:saxy, "~> 1.6"},
      {:shoehorn, "~> 0.9.1"},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:toolshed, "~> 0.5.0"},
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:nerves_runtime, "~> 0.13.12"},
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},
      # A production firmware holds no SSH daemon, so a board in a case is a board
      # that no person can reach. NervesCloud gives the one way back: it pushes a
      # firmware and it opens a console over a channel that the device starts
      # itself. See the NervesCloud section of `config/target.exs`.
      #
      # Every dependency of this package is Elixir or Erlang, so the custom system
      # needs nothing. The three optional ones that this firmware holds already are
      # `nerves_runtime`, `nerves_time` and `vintage_net`. It asks for `nerves_key`
      # and `tpm` as well, and this board holds neither, so the shared secret is
      # what it uses.
      {:nerves_hub_link, "~> 2.12", targets: @all_targets},
      # These two arrive through `nerves_pack`, and this firmware calls each one
      # itself, so naming them here means that a change there cannot take them
      # away. `req` is named for the same reason.
      #
      # `MyHiFi.Podcast.Index` asks `nerves_time` whether the clock is right,
      # because the Podcast Index holds a window of 3 minutes and a board with no
      # battery starts in 1970. `MyHiFi.Device.Network.Report` and
      # `MyHiFi.Setup.Monitor` read `vintage_net`.
      {:nerves_time, "~> 0.4", targets: @all_targets},
      {:vintage_net, "~> 0.13", targets: @all_targets},
      # Release 0.4.17 is from 2024-06-05, and it needs plug_cowboy. Each cowlib
      # release from 2.9.0 to 2.19.0 holds two advisories, and no release fixes
      # them. The main branch uses Bandit instead, and Phoenix already gives us
      # Bandit, so cowboy and cowlib leave the dependency tree.
      {:vintage_net_wizard,
       github: "nerves-networking/vintage_net_wizard", ref: "c11eabea849e", targets: @all_targets},

      # Targets
      {:nerves_system_bbb, "~> 2.19", runtime: false, targets: :bbb},
      {:nerves_system_mangopi_mq_pro, "~> 0.6", runtime: false, targets: :mangopi_mq_pro},
      {:nerves_system_qemu_aarch64, "~> 0.4", runtime: false, targets: :qemu_aarch64},
      {:nerves_system_rpi, "~> 2.0", runtime: false, targets: :rpi},
      {:nerves_system_rpi0, "~> 2.0", runtime: false, targets: :rpi0},
      # The stock rpi0_2 system holds no USB host stack and no USB audio driver,
      # so a USB DAC cannot work on it. It also gives 192 MB to the GPU and
      # reserves 128 MB of CMA, and this device drives no display over HDMI. See
      # the README of the system.
      {:nerves_system_myhifi_rpi0_2,
       git: "https://harton.dev/mypihifiguy/nerves_system_myhifi_rpi0_2.git",
       tag: "v0.1.2",
       runtime: false,
       targets: :myhifi_rpi0_2,
       nerves: [compile: true]},
      {:nerves_system_rpi2, "~> 2.0", runtime: false, targets: :rpi2},
      {:nerves_system_rpi3, "~> 2.0", runtime: false, targets: :rpi3},
      {:nerves_system_rpi4, "~> 2.0", runtime: false, targets: :rpi4},
      {:nerves_system_rpi5, "~> 2.0", runtime: false, targets: :rpi5},
      {:nerves_system_trellis, "~> 0.4", runtime: false, targets: :trellis},

      # Dev/test deps.
      {:credo, "~> 1.7", runtime: false, only: [:dev, :test], target: :host},
      # Phoenix LiveView needs this to read the HTML that a test renders.
      {:lazy_html, ">= 0.1.0", only: :test, target: :host},
      # `esbuild` and `tailwind` hold no target of their own on purpose. The
      # `firmware` alias runs `assets.deploy`, so a target build needs both tasks.
      # Each program runs on the build machine and writes to `priv/static`, and a
      # firmware build uses `MIX_ENV=prod`, so `runtime:` keeps both out of the
      # release.
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:ex_check_ng, "~> 1.0.0-rc.2", only: [:dev, :test], targets: :host},
      {:ex_doc, "~> 0.40", only: [:dev, :test], targets: :host},
      {:phx_install, "~> 0.1", only: [:dev], targets: :host},
      {:sobelow, "~> 0.15", only: [:dev, :test], targets: :host},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev}
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
  defp listeners(:host, :dev), do: [Phoenix.CodeReloader]
  defp listeners(_, _), do: []

  defp aliases() do
    [
      "assets.setup": ["esbuild.install --if-missing", "tailwind.install --if-missing"],
      "assets.build": ["compile", "esbuild my_hi_fi", "tailwind my_hi_fi"],
      "assets.deploy": ["esbuild my_hi_fi --minify", "tailwind my_hi_fi --minify", "phx.digest"],
      setup: ["deps.get", "assets.setup", "assets.build"],
      test: ["ash.setup --quiet", "test"],
      credo: ["credo --strict"],
      # `assets.deploy` comes first, because `priv/static/assets` holds no file
      # that the repository keeps, and the release copies `priv` as it finds it.
      # It also runs before `nbpr.fetch`, so a fault in the assets stops the build
      # before the 10 minutes that a source build of the NBPR packages needs.
      firmware: ["assets.deploy", "nbpr.fetch", "firmware"]
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
      build = Mix.Project.build_path()

      # `_build/<target>/lib/bundlex/priv` is a symbolic link into `deps`, and it
      # holds every architecture that any build has fetched. Replace the link with
      # a copy, so this step can remove the foreign libraries from the copy and
      # leave `deps` as it is.
      #
      # An earlier version of this step removed them from `deps` instead. That
      # broke each build for the host: the library beside a host NIF is itself a
      # symbolic link into that shared directory, and the NIF then failed to load
      # with `unifex_create/0 is undefined`.
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

    release
  end

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
