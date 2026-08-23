defmodule MyHiFiWeb.ArtworkControllerTest do
  use MyHiFiWeb.ConnCase, async: false

  alias MyHiFi.Artwork
  alias MyHiFi.Cache

  @png <<0x89, "PNG\r\n", 0x1A, "\n", "the rest of a small image">>

  setup do
    File.rm_rf(Artwork.directory())
    on_exit(fn -> File.rm_rf(Artwork.directory()) end)
    :ok
  end

  # The route reads a row of the cache and not a file of a directory, so a test that
  # wrote a file alone would get 404 for the right reason and the wrong one.
  defp write(name, body, content_type \\ "image/png") do
    {:ok, entry} = Cache.put("artwork", name, %{bytes: body, content_type: content_type})
    entry.entry_key
  end

  describe "show" do
    test "serves a logo of the cache", %{conn: conn} do
      name = write(String.duplicate("a", 64), @png)

      conn = get(conn, ~p"/artwork/#{name}")

      assert response(conn, 200) == @png
      assert response_content_type(conn, :png) =~ "image/png"
    end

    test "tells a browser to keep the answer", %{conn: conn} do
      name = write(String.duplicate("a", 64), @png)

      conn = get(conn, ~p"/artwork/#{name}")

      assert get_resp_header(conn, "cache-control") == ["public, max-age=604800, immutable"]
    end

    test "gives 404 for a name that the cache does not hold", %{conn: conn} do
      absent = String.duplicate("b", 64)
      conn = get(conn, ~p"/artwork/#{absent}")

      assert response(conn, 404)
    end

    test "gives 404 for a name that is not a hash", %{conn: conn} do
      # The row exists, and the name still does not hold 64 hexadecimal characters.
      write("my_hi_fi.db", "the database")

      conn = get(conn, ~p"/artwork/my_hi_fi.db")

      assert response(conn, 404)
    end

    test "gives 404 for a type that this device does not serve", %{conn: conn} do
      # The cache holds any bytes, and this route sends an image alone. Without this
      # a script of the cache would run with the rights of the web interface.
      name = write(String.duplicate("a", 64), "a script", "text/html")

      conn = get(conn, ~p"/artwork/#{name}")

      assert response(conn, 404)
    end

    test "gives 404 for a row whose file is gone", %{conn: conn} do
      name = write(String.duplicate("a", 64), @png)
      File.rm!(Path.join(Artwork.directory(), name))

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
