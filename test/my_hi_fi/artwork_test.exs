defmodule MyHiFi.ArtworkTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Artwork
  alias MyHiFi.Cache

  @png <<0x89, "PNG\r\n", 0x1A, "\n", "the rest of a small image">>
  @jpeg <<0xFF, 0xD8, 0xFF, "the rest of a small image">>
  @gif <<"GIF89a", "the rest of a small image">>
  @webp <<"RIFF", 26::little-32, "WEBP", "the rest of a small image">>

  setup do
    Application.put_env(:my_hi_fi, Artwork, plug: {Req.Test, Artwork}, retry: false)
    File.rm_rf(Artwork.directory())

    on_exit(fn ->
      Application.delete_env(:my_hi_fi, Artwork)
      Application.delete_env(:my_hi_fi, :cache_limit)
      File.rm_rf(Artwork.directory())
    end)

    :ok
  end

  # A name carries no extension now, because the type lives on the row of the cache.
  defp on_disk(name), do: Path.join(Artwork.directory(), name)

  defp held, do: Path.wildcard(Path.join(Artwork.directory(), "*")) |> Enum.map(&Path.basename/1)

  defp stub(type, body) do
    Req.Test.stub(Artwork, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type(type)
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  describe "fetch/1" do
    test "reads a logo and gives the name of the file" do
      stub("image/png", @png)

      assert {:ok, name} = Artwork.fetch("https://station.test/logo.png")
      assert String.match?(name, ~r/\A[0-9a-f]{64}\z/)
      assert File.read!(on_disk(name)) == @png
    end

    test "the same address gives the same name" do
      stub("image/png", @png)

      assert {:ok, one} = Artwork.fetch("https://station.test/logo.png")
      assert {:ok, two} = Artwork.fetch("https://station.test/logo.png")
      assert one == two
    end

    test "two addresses give two names" do
      stub("image/png", @png)

      assert {:ok, one} = Artwork.fetch("https://station.test/one.png")
      assert {:ok, two} = Artwork.fetch("https://station.test/two.png")
      refute one == two
    end

    test "reads the type from the answer, and not from the address" do
      # A station names a `.png` address and sends a JPEG.
      stub("image/jpeg", @jpeg)

      assert {:ok, name} = Artwork.fetch("https://station.test/logo.png")
      assert {:ok, _path, "image/jpeg"} = Artwork.serve(name)
    end

    # 11 New Zealand stations answer `image/x-icon`, and 8 of those send a PNG or a
    # JPEG. The header of the answer is therefore not the type.
    test "reads the type from the bytes, and not from the content type header" do
      stub("image/x-icon", @png)

      assert {:ok, name} = Artwork.fetch("https://station.test/favicon.ico")
      assert {:ok, _path, "image/png"} = Artwork.serve(name)
    end

    test "reads a GIF and a WebP from their bytes" do
      stub("application/octet-stream", @gif)
      assert {:ok, gif} = Artwork.fetch("https://station.test/one")
      assert {:ok, _path, "image/gif"} = Artwork.serve(gif)

      stub("application/octet-stream", @webp)
      assert {:ok, webp} = Artwork.fetch("https://station.test/two")
      assert {:ok, _path, "image/webp"} = Artwork.serve(webp)
    end

    test "refuses an answer that is not an image" do
      stub("text/html", "<html>not found</html>")

      assert {:error, {:not_an_image, "text/html"}} =
               Artwork.fetch("https://station.test/logo.png")
    end

    # A server that names an image and sends a page must not fill the cache with
    # that page. The bytes decide, so this answer goes nowhere.
    test "refuses a page that names itself an image" do
      stub("image/png", "<html>not found</html>")

      assert {:error, {:not_an_image, "image/png"}} =
               Artwork.fetch("https://station.test/logo.png")
    end

    # An SVG file can hold a script, and this device serves each logo from its own
    # address. No signature clause names SVG, so it never reaches the disk.
    test "refuses an SVG file" do
      stub("image/svg+xml", ~s(<svg xmlns="http://www.w3.org/2000/svg"></svg>))

      assert {:error, {:not_an_image, "image/svg+xml"}} =
               Artwork.fetch("https://station.test/logo.svg")
    end

    # A true icon is 32 by 32 pixels or smaller, and the device screen cannot read
    # the format. The cache holds the four formats that it can read.
    test "refuses a true icon" do
      stub("image/x-icon", <<0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x20, 0x20>>)

      assert {:error, {:not_an_image, "image/x-icon"}} =
               Artwork.fetch("https://station.test/favicon.ico")
    end

    test "refuses an image that is too large for a logo" do
      stub("image/png", String.duplicate("x", 5 * 1024 * 1024))

      assert {:error, {:too_large, _bytes}} = Artwork.fetch("https://station.test/big.png")
    end

    test "gives an error for an answer that is not 200" do
      Req.Test.stub(Artwork, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert {:error, {:status, 404}} = Artwork.fetch("https://station.test/gone.png")
    end

    test "gives an error for no address" do
      assert {:error, :no_address} = Artwork.fetch(nil)
      assert {:error, :no_address} = Artwork.fetch("")
    end
  end

  describe "name/1" do
    test "gives nothing for an address that the cache does not hold" do
      assert Artwork.name("https://station.test/absent.png") == nil
    end

    test "gives the name after a read" do
      stub("image/png", @png)
      {:ok, name} = Artwork.fetch("https://station.test/logo.png")

      assert Artwork.name("https://station.test/logo.png") == name
    end

    test "gives nothing for no address" do
      assert Artwork.name(nil) == nil
      assert Artwork.name("") == nil
    end
  end

  describe "serve/1" do
    test "it gives the path and the type of an entry that the cache holds" do
      stub("image/png", @png)
      {:ok, name} = Artwork.fetch("https://station.test/logo.png")

      assert {:ok, path, "image/png"} = Artwork.serve(name)
      assert path == on_disk(name)
      assert File.read!(path) == @png
    end

    test "it notes that something used the entry, so the eviction can order them" do
      stub("image/png", @png)
      {:ok, name} = Artwork.fetch("https://station.test/logo.png")
      {:ok, before} = Cache.fetch("artwork", name)

      Process.sleep(5)
      assert {:ok, _path, _type} = Artwork.serve(name)

      {:ok, after_serving} = Cache.fetch("artwork", name)
      assert DateTime.compare(after_serving.last_accessed_at, before.last_accessed_at) == :gt
    end

    test "a name that could reach another file gives nothing" do
      for name <- [
            "../secret_key_base",
            "../../etc/passwd",
            "/etc/passwd",
            "my_hi_fi.db",
            String.duplicate("a", 64) <> ".exs",
            String.duplicate("a", 63),
            String.duplicate("z", 64),
            "",
            nil
          ] do
        assert Artwork.serve(name) == :error, "#{inspect(name)} was served"
      end
    end

    test "a name that no entry holds gives nothing" do
      assert Artwork.serve(String.duplicate("a", 64)) == :error
    end

    test "an entry of a type that this route does not serve gives nothing" do
      # The cache holds any bytes, and this route sends an image alone.
      {:ok, entry} =
        Cache.put("artwork", String.duplicate("b", 64), %{
          bytes: "a script",
          content_type: "text/html"
        })

      assert Artwork.serve(entry.entry_key) == :error
    end

    test "a row with no file gives nothing" do
      stub("image/png", @png)
      {:ok, name} = Artwork.fetch("https://station.test/logo.png")
      File.rm!(on_disk(name))

      assert Artwork.serve(name) == :error
    end
  end

  describe "the eviction" do
    test "a read of a new picture removes a colder one when the cache is full" do
      stub("image/png", @png)
      {:ok, old} = Artwork.fetch("https://station.test/old.png")

      # The limit holds one picture of this size and not two.
      Application.put_env(:my_hi_fi, :cache_limit, byte_size(@png) + 1)

      Process.sleep(5)
      stub("image/jpeg", @jpeg)
      assert {:ok, new} = Artwork.fetch("https://station.test/new.jpg")

      assert new in held()
      refute old in held()
    end

    test "it removes nothing while the cache is inside its limit" do
      stub("image/png", @png)
      {:ok, name} = Artwork.fetch("https://station.test/logo.png")

      assert length(held()) == 1
      assert name in held()
    end

    test "the picture that a person looked at lately stays" do
      stub("image/png", @png)
      {:ok, first} = Artwork.fetch("https://station.test/one.png")
      stub("image/gif", @gif)
      {:ok, second} = Artwork.fetch("https://station.test/two.gif")

      # Serving the first one makes the second the colder of the two.
      Process.sleep(5)
      {:ok, _path, _type} = Artwork.serve(first)

      # The limit holds two pictures of this size, so one of the three goes.
      Application.put_env(:my_hi_fi, :cache_limit, byte_size(@png) * 2 + 10)
      Process.sleep(5)
      stub("image/jpeg", @jpeg)
      assert {:ok, third} = Artwork.fetch("https://station.test/three.jpg")

      # The one that nothing looked at lately is the one that went.
      assert first in held()
      assert third in held()
      refute second in held()
    end
  end
end
