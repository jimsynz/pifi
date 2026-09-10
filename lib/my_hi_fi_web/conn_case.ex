defmodule MyHiFiWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias MyHiFi.Settings.Cache

  using do
    quote do
      @endpoint MyHiFiWeb.Endpoint

      use MyHiFiWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import MyHiFiWeb.ConnCase
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(MyHiFi.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    # A rollback takes a row away, and the memory of the settings cannot see that.
    # See `MyHiFi.Settings.Cache`.
    Cache.clear()

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
