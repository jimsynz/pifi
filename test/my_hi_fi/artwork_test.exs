defmodule MyHiFi.ArtworkTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Artwork

  @png <<0x89, "PNG\r\n", 0x1A, "\n", "the rest of a small image">>
  @jpeg <<0xFF, 0xD8, 0xFF, "the rest of a small image">>
  @gif <<"GIF89a", "the rest of a small image">>
  @webp <<"RIFF", 26::little-32, "WEBP", "the rest of a small image">>

  setup do
    Application.put_env(:my_hi_fi, Artwork, plug: {Req.Test, Artwork}, retry: false)
    File.rm_rf(Artwork.directory())

    on_exit(fn ->
      Application.delete_env(:my_hi_fi, Artwork)
      File.rm_rf(Artwork.directory())
    end)

    :ok
  end

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
      assert String.match?(name, ~r/\A[0-9a-f]{64}\.png\z/)
      assert File.read!(Artwork.path(name)) == @png
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
      assert String.ends_with?(name, ".jpg")
    end

    # 11 New Zealand stations answer `image/x-icon`, and 8 of those send a PNG or a
    # JPEG. The header of the answer is therefore not the type.
    test "reads the type from the bytes, and not from the content type header" do
      stub("image/x-icon", @png)

      assert {:ok, name} = Artwork.fetch("https://station.test/favicon.ico")
      assert String.ends_with?(name, ".png")
      assert Artwork.content_type(name) == "image/png"
    end

    test "reads a GIF and a WebP from their bytes" do
      stub("application/octet-stream", @gif)
      assert {:ok, gif} = Artwork.fetch("https://station.test/one")
      assert String.ends_with?(gif, ".gif")

      stub("application/octet-stream", @webp)
      assert {:ok, webp} = Artwork.fetch("https://station.test/two")
      assert String.ends_with?(webp, ".webp")
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

  describe "path/1" do
    test "gives a path for a hash and a known extension" do
      name = String.duplicate("a", 64) <> ".png"

      assert Artwork.path(name) == Path.join(Artwork.directory(), name)
    end

    test "gives nothing for a name that could reach another file" do
      for name <- [
            "../secret_key_base",
            "../../etc/passwd",
            "/etc/passwd",
            "my_hi_fi.db",
            String.duplicate("a", 64) <> ".exs",
            String.duplicate("a", 63) <> ".png",
            String.duplicate("z", 64) <> ".png",
            String.duplicate("a", 64),
            "",
            nil
          ] do
        assert Artwork.path(name) == nil, "#{inspect(name)} gave a path"
      end
    end
  end

  describe "prune/0" do
    test "removes nothing while the cache is inside its limit" do
      stub("image/png", @png)
      {:ok, _name} = Artwork.fetch("https://station.test/logo.png")

      assert Artwork.prune() == 0
      assert length(Path.wildcard(Path.join(Artwork.directory(), "*"))) == 1
    end

    test "removes the oldest file first" do
      File.mkdir_p!(Artwork.directory())

      # Each file holds 400 bytes, and the limit allows two of them.
      names =
        for index <- 1..4 do
          name = String.duplicate(Integer.to_string(index), 64) <> ".png"
          path = Path.join(Artwork.directory(), name)
          File.write!(path, String.duplicate("x", 400))
          # `prune/0` sorts by the write time, and that time holds whole seconds.
          File.touch!(path, 1_700_000_000 + index)
          name
        end

      Application.put_env(:my_hi_fi, :artwork_max_bytes, 900)
      on_exit(fn -> Application.delete_env(:my_hi_fi, :artwork_max_bytes) end)

      assert Artwork.prune() == 2

      held = Path.wildcard(Path.join(Artwork.directory(), "*")) |> Enum.map(&Path.basename/1)

      # The two oldest went, and the two newest stayed.
      refute Enum.at(names, 0) in held
      refute Enum.at(names, 1) in held
      assert Enum.at(names, 2) in held
      assert Enum.at(names, 3) in held
    end

    test "a read of a new logo removes an old one when the cache is full" do
      File.mkdir_p!(Artwork.directory())
      old = String.duplicate("f", 64) <> ".png"
      File.write!(Path.join(Artwork.directory(), old), String.duplicate("x", 800))
      File.touch!(Path.join(Artwork.directory(), old), 1_700_000_000)

      Application.put_env(:my_hi_fi, :artwork_max_bytes, 500)
      on_exit(fn -> Application.delete_env(:my_hi_fi, :artwork_max_bytes) end)

      stub("image/png", @png)

      assert {:ok, name} = Artwork.fetch("https://station.test/new.png")

      held = Path.wildcard(Path.join(Artwork.directory(), "*")) |> Enum.map(&Path.basename/1)

      assert name in held
      refute old in held
    end
  end

  describe "limit/0" do
    test "is a part of the free space, and it stops at 64 MB" do
      limit = Artwork.limit()

      assert limit > 0
      assert limit <= 64 * 1024 * 1024
    end
  end
end
