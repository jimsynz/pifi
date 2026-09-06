defmodule MyHiFi.Artwork.WorkerTest do
  use MyHiFi.DataCase, async: false
  use Oban.Testing, repo: MyHiFi.Repo

  alias MyHiFi.Artwork
  alias MyHiFi.Artwork.Worker
  alias MyHiFi.Event

  @png <<0x89, "PNG\r\n", 0x1A, "\n", "a small image">>
  @url "https://station.test/logo.png"

  setup do
    Application.put_env(:my_hi_fi, Artwork, plug: {Req.Test, Artwork}, retry: false)
    File.rm_rf(Artwork.directory())

    on_exit(fn ->
      Application.delete_env(:my_hi_fi, Artwork)
      File.rm_rf(Artwork.directory())
    end)

    :ok
  end

  defp stub(type, body, status \\ 200) do
    Req.Test.stub(Artwork, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type(type)
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  defp perform(url \\ @url, announce? \\ true) do
    Worker.perform(%Oban.Job{args: %{"url" => url, "announce" => announce?}})
  end

  describe "a logo that arrives" do
    test "stores it and tells the player topic when the caller asked for that" do
      Event.subscribe(:player)
      stub("image/png", @png)

      assert perform() == :ok

      name = Artwork.name(@url)
      assert is_binary(name)

      assert_receive %MyHiFi.Event.Player.MetadataChanged{artwork_path: path}
      assert path == "/artwork/#{name}"
    end

    # `MyHiFi.Jellyfin.Fill` asks for the picture of each container of a library, and a
    # library holds thousands. Each one that told the player topic showed its own
    # picture as though it were the track that plays, so a person reading the library
    # watched the panel move through album covers while it said `Nothing selected`.
    test "it tells the player topic nothing when the caller did not ask" do
      Event.subscribe(:player)
      stub("image/png", @png)

      assert perform(@url, false) == :ok

      assert is_binary(Artwork.name(@url))
      refute_receive %MyHiFi.Event.Player.MetadataChanged{}, 200
    end

    # A job of an older firmware holds no such key, and it must not announce either.
    test "a job that names no answer tells the player topic nothing" do
      Event.subscribe(:player)
      stub("image/png", @png)

      assert Worker.perform(%Oban.Job{args: %{"url" => @url}}) == :ok

      refute_receive %MyHiFi.Event.Player.MetadataChanged{}, 200
    end
  end

  describe "an answer that cannot become a logo" do
    test "a page instead of an image stops the job for good" do
      # A station that holds no image cannot start to hold one, so a retry is
      # waste. `:cancel` tells Oban to stop.
      stub("text/html", "<html>not found</html>")

      assert {:cancel, :not_an_image} = perform()
    end

    test "an image that is too large stops the job for good" do
      stub("image/png", String.duplicate("x", 5 * 1024 * 1024))

      assert {:cancel, :too_large} = perform()
    end

    test "an answer of 404 stops the job for good" do
      stub("image/png", "", 404)

      assert {:cancel, {:status, 404}} = perform()
    end

    test "an answer of 403 stops the job for good" do
      stub("image/png", "", 403)

      assert {:cancel, {:status, 403}} = perform()
    end
  end

  describe "an answer that may come right later" do
    test "a fault of the server gives a retry" do
      # 500 is not in 400..499, so this one comes back.
      stub("image/png", "", 500)

      assert {:error, {:status, 500}} = perform()
    end

    test "a network fault gives a retry" do
      Req.Test.stub(Artwork, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, _reason} = perform()
    end
  end

  describe "enqueue/2" do
    test "asks for a logo that the cache does not hold, and announces nothing" do
      assert Worker.enqueue(@url) == :ok
      assert_enqueued(worker: Worker, args: %{"url" => @url, "announce" => false})
    end

    test "the player asks for an answer, and it gets one" do
      assert Worker.enqueue(@url, true) == :ok
      assert_enqueued(worker: Worker, args: %{"url" => @url, "announce" => true})
    end

    test "asks for nothing when the cache holds the logo" do
      stub("image/png", @png)
      {:ok, _name} = Artwork.fetch(@url)

      assert Worker.enqueue(@url) == :ok
      refute_enqueued(worker: Worker, args: %{"url" => @url})
    end

    test "asks for nothing without an address" do
      assert Worker.enqueue(nil) == :ok
      assert Worker.enqueue("", true) == :ok
      refute_enqueued(worker: Worker)
    end
  end
end
