defmodule MyHiFiWeb.RouterTest do
  @moduledoc """
  What every page of this device carries, whichever route drew it.
  """

  use MyHiFiWeb.ConnCase, async: false

  # **The policy belongs to the pipeline, so this asks for the cheapest route of it.**
  # A page of the interface starts the player and reads the settings, and none of that
  # decides one header.
  @route "/artwork/none"

  describe "the content security policy" do
    # **A policy that names no `connect-src` closes the LiveView socket on WebKit.**
    # CSP Level 3 says that `'self'` matches `ws:` and `wss:` of the same host, and
    # WebKit does not hold that rule, so Safari and every browser of iOS drew the page
    # and refused the socket. LiveView then used long poll, so the interface worked and
    # nothing said why it was slow.
    test "it lets a page open the socket of this device", %{conn: conn} do
      conn = get(conn, @route)

      assert [policy] = get_resp_header(conn, "content-security-policy")
      assert policy =~ "connect-src 'self' ws: wss:"
    end

    # A page of this device reads pictures from this device, and nothing else from
    # anywhere. See `MyHiFi.Artwork`.
    test "it reads nothing from another server", %{conn: conn} do
      conn = get(conn, @route)

      assert [policy] = get_resp_header(conn, "content-security-policy")
      assert policy =~ "default-src 'self'"
      assert policy =~ "img-src 'self' data:"
    end
  end
end
