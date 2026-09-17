defmodule PiFi.Artwork.WorkerTest do
  use PiFi.DataCase, async: false
  use Oban.Testing, repo: PiFi.Repo

  alias PiFi.Artwork
  alias PiFi.Artwork.Worker
  alias PiFi.Event

  @png <<0x89, "PNG\r\n", 0x1A, "\n", "a small image">>
  @url "https://station.test/logo.png"

  setup do
    Application.put_env(:pifi, Artwork, plug: {Req.Test, Artwork}, retry: false)
    File.rm_rf(Artwork.directory())

    on_exit(fn ->
      Application.delete_env(:pifi, Artwork)
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
    Worker.perform(%Oban.Job{args: %{"urls" => [url], "announce" => announce?}})
  end

  describe "a logo that arrives" do
    test "stores it and tells the player topic when the caller asked for that" do
      Event.subscribe(:player)
      stub("image/png", @png)

      assert perform() == :ok

      name = Artwork.name(@url)
      assert is_binary(name)

      assert_receive %PiFi.Event.Player.MetadataChanged{artwork_path: path}
      assert path == "/artwork/#{name}"
    end

    # `PiFi.Jellyfin.Fill` asks for the picture of each container of a library, and a
    # library holds thousands. Each one that told the player topic showed its own
    # picture as though it were the track that plays, so a person reading the library
    # watched the panel move through album covers while it said `Nothing selected`.
    test "it tells the player topic nothing when the caller did not ask" do
      Event.subscribe(:player)
      stub("image/png", @png)

      assert perform(@url, false) == :ok

      assert is_binary(Artwork.name(@url))
      refute_receive %PiFi.Event.Player.MetadataChanged{}, 200
    end

    # A job of an older firmware holds no such key, and it must not announce either.
    test "a job that names no answer tells the player topic nothing" do
      Event.subscribe(:player)
      stub("image/png", @png)

      assert Worker.perform(%Oban.Job{args: %{"url" => @url}}) == :ok

      refute_receive %PiFi.Event.Player.MetadataChanged{}, 200
    end
  end

  # **A station that holds no image cannot start to hold one, so a retry is waste.** The
  # job holds a list, and one address of that kind must leave the rest of the list read,
  # so the job finishes and stores nothing for that address.
  describe "an answer that cannot become a logo" do
    test "a page instead of an image stores nothing, and the job finishes" do
      stub("text/html", "<html>not found</html>")

      assert perform() == :ok
      assert Artwork.name(@url) == nil
    end

    test "an image that is too large stores nothing" do
      stub("image/png", String.duplicate("x", 5 * 1024 * 1024))

      assert perform() == :ok
      assert Artwork.name(@url) == nil
    end

    test "an answer of 404 stores nothing" do
      stub("image/png", "", 404)

      assert perform() == :ok
      assert Artwork.name(@url) == nil
    end

    test "an answer of 403 stores nothing" do
      stub("image/png", "", 403)

      assert perform() == :ok
      assert Artwork.name(@url) == nil
    end

    # A list of a library holds a few addresses that can never hold a picture, and the
    # rest of that list must still arrive.
    test "one address that cannot become a logo leaves the rest of the list read" do
      Req.Test.stub(Artwork, fn conn ->
        if conn.request_path =~ "bad" do
          conn
          |> Plug.Conn.put_resp_content_type("text/html")
          |> Plug.Conn.send_resp(200, "<html>not found</html>")
        else
          conn
          |> Plug.Conn.put_resp_content_type("image/png")
          |> Plug.Conn.send_resp(200, @png)
        end
      end)

      good = "https://station.test/good.png"

      assert Worker.perform(%Oban.Job{
               args: %{"urls" => ["https://station.test/bad.png", good]}
             }) == :ok

      assert is_binary(Artwork.name(good))
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
      assert_enqueued(worker: Worker, args: %{"urls" => [@url], "announce" => false})
    end

    test "the player asks for an answer, and it gets one" do
      assert Worker.enqueue(@url, true) == :ok
      assert_enqueued(worker: Worker, args: %{"urls" => [@url], "announce" => true})
    end

    # A person is waiting for the logo of the track that starts, and a read of a library
    # holds 80 minutes of jobs in front of it. Oban runs the lower number first.
    test "the ask of the player goes before a read of a library" do
      assert Worker.enqueue(@url, true) == :ok
      assert Worker.enqueue_all(["https://station.test/one.png"]) == :ok

      assert [asked, bulk] = Enum.sort_by(all_enqueued(worker: Worker), & &1.priority)
      assert asked.args["announce"] == true
      assert asked.priority < bulk.priority
    end

    test "asks for nothing when the cache holds the logo" do
      stub("image/png", @png)
      {:ok, _name} = Artwork.fetch(@url)

      assert Worker.enqueue(@url) == :ok
      refute_enqueued(worker: Worker)
    end

    test "asks for nothing without an address" do
      assert Worker.enqueue(nil) == :ok
      assert Worker.enqueue("", true) == :ok
      refute_enqueued(worker: Worker)
    end
  end

  # **A read of a library asks for thousands of pictures at one time**, and a job for
  # each of them costs the card a write, a read and a delete.
  describe "enqueue_all/1" do
    test "a list of addresses becomes one job" do
      urls = for index <- 1..10, do: "https://station.test/#{index}.png"

      assert Worker.enqueue_all(urls) == :ok

      assert [job] = all_enqueued(worker: Worker)
      assert job.args["urls"] == urls
      assert job.args["announce"] == false
    end

    test "a list longer than one job holds becomes more of them" do
      urls = for index <- 1..(Worker.batch_size() + 1), do: "https://station.test/#{index}.png"

      assert Worker.enqueue_all(urls) == :ok

      assert [first, second] =
               Enum.sort_by(all_enqueued(worker: Worker), &length(&1.args["urls"]))

      assert length(second.args["urls"]) == Worker.batch_size()
      assert length(first.args["urls"]) == 1
    end

    test "an empty list writes no job" do
      assert Worker.enqueue_all([]) == :ok
      refute_enqueued(worker: Worker)
    end
  end

  # A device that takes this firmware holds jobs of the one before it, and each of
  # those names one address under another key.
  describe "a job of an older firmware" do
    test "one address under the old key still reads" do
      stub("image/png", @png)

      assert Worker.perform(%Oban.Job{args: %{"url" => @url, "announce" => false}}) == :ok
      assert is_binary(Artwork.name(@url))
    end
  end
end
