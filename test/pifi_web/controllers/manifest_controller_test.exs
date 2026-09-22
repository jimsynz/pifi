defmodule PiFiWeb.ManifestControllerTest do
  use PiFiWeb.ConnCase, async: false

  alias Nerves.Runtime.KV
  alias PiFi.Device.Identity

  describe "the manifest" do
    test "a telephone reads JSON of the type it expects", %{conn: conn} do
      conn = get(conn, ~p"/site.webmanifest")

      assert response_content_type(conn, :json) =~ "application/manifest+json"
      assert {:ok, manifest} = JSON.decode(response(conn, 200))
      assert manifest["start_url"] == "/"
      assert manifest["display"] == "standalone"
    end

    # **A household with two of these installs two icons**, and two that said the same
    # word would be a coin toss every time somebody wanted the one in the kitchen.
    test "it carries the name of this device and not the name of the product", %{conn: conn} do
      KV.put("pifi_device_name", "Kitchen")

      manifest = conn |> get(~p"/site.webmanifest") |> response(200) |> JSON.decode!()

      assert manifest["name"] == "Kitchen"
      assert manifest["short_name"] == Identity.default_name()
    end

    # A device that nobody has named still installs as something a person recognises.
    test "a device with no name of its own falls back to the product", %{conn: conn} do
      KV.put("pifi_device_name", "")

      manifest = conn |> get(~p"/site.webmanifest") |> response(200) |> JSON.decode!()

      assert manifest["name"] == Identity.default_name()
    end

    # Android masks an icon to whatever shape the launcher draws, and it crops one that
    # is not marked. See `priv/static/icons/icon-maskable-512.png`.
    test "it offers a maskable icon as well as a plain one", %{conn: conn} do
      manifest = conn |> get(~p"/site.webmanifest") |> response(200) |> JSON.decode!()

      assert Enum.any?(manifest["icons"], &(&1["purpose"] == "maskable"))
      assert Enum.any?(manifest["icons"], &is_nil(&1["purpose"]))
    end

    test "every icon it names is one this firmware serves", %{conn: conn} do
      manifest = conn |> get(~p"/site.webmanifest") |> response(200) |> JSON.decode!()

      for icon <- manifest["icons"] do
        assert conn |> get(icon["src"]) |> response(200) != ""
      end
    end
  end

  # The same rule as the pictures of `priv/splash`: a name that claims a size and a file
  # that is another one costs a person a blurred icon and says nothing about why.
  describe "the icons that ship" do
    # **The names are written out rather than globbed.** `mix phx.digest` writes
    # `icon-192-<hash>.png` beside each one, and a glob would measure those too and read
    # the hash as the size it claims.
    test "each one is the size that its name claims" do
      for {name, size} <- [
            {"icon-192.png", 192},
            {"icon-512.png", 512},
            {"icon-maskable-512.png", 512}
          ] do
        path = Path.join([:code.priv_dir(:pifi), "static/icons", name])

        assert File.exists?(path), "#{name} does not ship"
        assert {output, 0} = System.cmd("file", [path])
        assert output =~ "#{size} x #{size}", "#{name} is not #{size} by #{size}"
      end
    end

    test "the one Safari asks for is there, and it is square" do
      path = Path.join(:code.priv_dir(:pifi), "static/icons/apple-touch-icon.png")

      assert File.exists?(path)
      assert {output, 0} = System.cmd("file", [path])
      assert output =~ "180 x 180"
    end
  end
end
