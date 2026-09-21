defmodule PiFi.RepoTest do
  @moduledoc """
  The settings of the database that a wrong value would cost this device rows.

  These read configuration, which is usually not worth a test. This one is, because the
  value it reads was measured on hardware and nothing else in the suite would notice it
  going: the host runs one test at a time against its own file, so the contention that
  this guards against cannot happen here.
  """

  use ExUnit.Case, async: true

  # **A deferred transaction that reads and then writes cannot keep its snapshot** once
  # another connection has committed, and SQLite answers `SQLITE_BUSY` for that at once
  # without calling the busy handler. The 10 second timeout of `config/target.exs`
  # therefore never applies, and the caller sees `Database busy` with no wait at all.
  #
  # A measurement on a board on 2026-09-21, 200 read-then-write transactions four at a
  # time, which is what two Oban queues and a page come to:
  #
  #     DEFERRED    76 of 200
  #     IMMEDIATE  200 of 200
  #
  # `Oban.Pruner` is that shape, and so is `PiFi.Cache.Entry`, and both were losing
  # writes on a device.
  test "a transaction takes the write lock as it begins" do
    assert Application.get_env(:pifi, PiFi.Repo)[:default_transaction_mode] == :immediate
  end

  # A prune of 10,000 rows in one statement holds the write lock for as long as it
  # takes, and with the mode above the lock is held for the whole transaction. A read of
  # a library writes one artwork job for each container, so the table reaches that size.
  test "the pruner removes jobs in batches that do not hold the lock" do
    plugins = Application.get_env(:pifi, Oban)[:plugins]

    assert {Oban.Plugins.Pruner, options} =
             Enum.find(plugins, &match?({Oban.Plugins.Pruner, _options}, &1))

    assert options[:limit] <= 1_000
  end
end
