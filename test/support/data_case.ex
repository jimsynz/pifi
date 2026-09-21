defmodule PiFi.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use PiFi.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias Nerves.Runtime.KV
  alias PiFi.Settings.Cache

  # **The sandbox rolls the database back and it can roll nothing else back.** These
  # four live outside it and outlive a test, so one test sets them and the next inherits
  # them. That cost eight CI runs, each failing a different test: a player left playing,
  # a device left named, a download left asking. See the module documentation.
  @identity_keys ~w(
    pifi_device_name pifi_product_name pifi_splash_name
    myhifi_device_name myhifi_product_name myhifi_splash_name
  )

  using do
    quote do
      alias PiFi.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PiFi.DataCase
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(PiFi.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    # A rollback takes a row away, and the memory of the settings cannot see that.
    # See `PiFi.Settings.Cache`.
    Cache.clear()

    # **Before the test and not after it.** A teardown only runs for the test that made
    # the mess, and the tests that failed were the ones that inherited it. Clearing at
    # the start means a test that leaves something behind costs itself and nobody else.
    #
    # It runs before the `setup` of the module, because `ExUnit.CaseTemplate` puts this
    # first, so a test that names a device or starts a track in its own setup keeps it.
    forget_the_device()
    quiet_the_player()

    :ok
  end

  @doc """
  Put the firmware key store back to a device that a provisioner never touched.

  `Nerves.Runtime.KV` is one store for the whole node and a host build keeps it in
  memory, so a name written by one test is the name that the next one reads. A test of
  `PiFi.Device.Identity` failed that way in CI, reading `PiFi` where it had just written
  `Acme Audio`.
  """
  @spec forget_the_device() :: :ok
  def forget_the_device do
    for key <- @identity_keys, do: KV.put(key, "")

    :ok
  end

  @doc """
  Stop a track that another test left playing.

  `PiFi.Player` is one process for the whole node. A track that outlives the test that
  started it is still playing when the next one runs, and an output double that raises
  on `sink_spec/1` then raises inside whichever test happens to be running. CI failed
  `PiFi.DeviceUiTest` that way, which has nothing to do with outputs.

  **It asks before it stops**, so a suite of two thousand tests pays one call each and
  the event only goes out when there is something to say.
  """
  @spec quiet_the_player() :: :ok
  def quiet_the_player do
    case PiFi.Player.state(1_000) do
      %{item: nil} -> :ok
      _playing -> PiFi.Player.stop()
    end

    :ok
  catch
    # A player that is busy or absent is one that this cannot tidy, and a test that
    # needed it tidy will say so itself.
    :exit, _reason -> :ok
  end
end
