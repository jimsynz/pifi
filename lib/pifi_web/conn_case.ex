defmodule PiFiWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias PiFi.Settings.Cache

  using do
    quote do
      @endpoint PiFiWeb.Endpoint

      use PiFiWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PiFiWeb.ConnCase
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(PiFi.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    # A rollback takes a row away, and the memory of the settings cannot see that.
    # See `PiFi.Settings.Cache`.
    Cache.clear()

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
