# Used by "mix format"
[
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "rootfs_overlay/etc/iex.exs"
  ],
  import_deps: [
    :cinder,
    :ash_state_machine,
    :ash_oban,
    :oban,
    :ash_sqlite,
    :ash,
    :reactor,
    :gettext,
    :phoenix
  ],
  plugins: [Spark.Formatter]
]
