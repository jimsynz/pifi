defmodule MyHiFiWeb.ArtworkControllerTest do
  use MyHiFiWeb.ConnCase, async: false

  alias MyHiFi.Artwork

  @png <<0x89, "PNG\r\n", 0x1A, "\n", "the rest of a small image">>

  setup do
    File.rm_rf(Artwork.directory())
    on_exit(fn -> File.rm_rf(Artwork.directory()) end)
    :ok
  end

  defp write(name, body) do
    File.mkdir_p!(Artwork.directory())
    File.write!(Path.join(Artwork.directory(), name), body)
    name
  end

  describe "show" do
    test "serves a logo of the cache", %{conn: conn} do
      name = write(String.duplicate("a", 64) <> ".png", @png)

      conn = get(conn, ~p"/artwork/#{name}")

      assert response(conn, 200) == @png
      assert response_content_type(conn, :png) =~ "image/png"
    end

    test "tells a browser to keep the answer", %{conn: conn} do
      name = write(String.duplicate("a", 64) <> ".png", @png)

      conn = get(conn, ~p"/artwork/#{name}")

      assert get_resp_header(conn, "cache-control") == ["public, max-age=604800, immutable"]
    end

    test "gives 404 for a name that the cache does not hold", %{conn: conn} do
      absent = String.duplicate("b", 64) <> ".png"
      conn = get(conn, ~p"/artwork/#{absent}")

      assert response(conn, 404)
    end

    test "gives 404 for a name that is not a hash", %{conn: conn} do
      write("my_hi_fi.db", "the database")

      conn = get(conn, ~p"/artwork/my_hi_fi.db")

      assert response(conn, 404)
    end

    test "gives 404 for a name with an extension that this device does not serve",
         %{conn: conn} do
      name = write(String.duplicate("a", 64) <> ".exs", "a script")

      conn = get(conn, ~p"/artwork/#{name}")

      assert response(conn, 404)
    end

    test "a name that points outside the cache reaches no file", %{conn: conn} do
      # The router gives one path piece, so a name with a slash cannot match this
      # route at all. A name of dots still gives 404.
      conn = get(conn, ~p"/artwork/#{".."}")

      assert response(conn, 404)
    end
  end
end
