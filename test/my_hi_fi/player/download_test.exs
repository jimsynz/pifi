defmodule MyHiFi.Player.DownloadTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Cache
  alias MyHiFi.Player.Download

  @id "episode-1"
  @uri "https://example.test/episode.mp3"

  setup do
    Application.put_env(:my_hi_fi, Download, plug: {Req.Test, Download}, retry: false)
    Req.Test.set_req_test_from_context(%{async: false})

    clean = fn ->
      File.rm_rf(Cache.directory())
      File.rm_rf(Download.directory())
    end

    clean.()

    on_exit(fn ->
      Application.delete_env(:my_hi_fi, Download)
      clean.()
    end)

    :ok
  end

  defp serve(body, options \\ []) do
    status = Keyword.get(options, :status, 200)
    headers = Keyword.get(options, :headers, [])

    Req.Test.stub(Download, fn conn ->
      conn =
        Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_resp_header(acc, k, v) end)

      Plug.Conn.send_resp(conn, status, body)
    end)
  end

  # The process stops as soon as it finishes, so a test waits for the message and
  # not for the process.
  defp await(message, timeout \\ 2000) do
    receive do
      {:download, ^message} -> :ok
    after
      timeout -> flunk("no #{inspect(message)} in #{timeout} ms")
    end
  end

  # `ensure/2` subscribes the caller as it starts the download, so nothing can
  # finish before this test is listening.
  defp start(id \\ @id, uri \\ @uri) do
    {:ok, paths} = Download.ensure(id, uri)
    paths
  end

  describe "ensure" do
    test "it reads the episode and puts it in the cache" do
      serve("the audio")
      start()

      await(:done)

      assert {:ok, entry} = Cache.fetch(Download.namespace(), @id)
      assert entry.byte_size == 9
      assert entry.content_type == "audio/mpeg"
      assert File.read!(Path.join(Cache.directory(), entry.key)) == "the audio"
    end

    test "the entry holds a mark to keep, so no eviction takes an episode in play" do
      serve("the audio")
      start()
      await(:done)

      assert {:ok, entry} = Cache.fetch(Download.namespace(), @id)
      assert entry.keep? == true
    end

    test "the partial file is gone when the file is whole" do
      serve("the audio")
      start()
      await(:done)

      refute File.exists?(Path.join(Download.directory(), @id))
    end

    test "it tells a watcher how many bytes the file holds" do
      serve("the audio")
      start()

      await({:bytes, 9})
      await(:done)
    end

    test "it gives the path of the cache when the cache already holds the episode" do
      serve("the audio")
      start()
      await(:done)

      assert {:ok, %{paths: paths, complete?: true}} = Download.ensure(@id, @uri)
      assert paths == [Path.join([Cache.directory(), Download.namespace(), @id])]
    end

    test "a second call for one episode holds no second download" do
      # A body that the stub sends in parts keeps the first download in flight long
      # enough for the second call to find it.
      Req.Test.stub(Download, fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(1..4, conn, fn _part, acc ->
          Process.sleep(25)
          {:ok, acc} = Plug.Conn.chunk(acc, "audio")
          acc
        end)
      end)

      assert {:ok, _first} = Download.ensure(@id, @uri)
      assert Registry.count(Download.Registry) == 1
      assert {:ok, _second} = Download.ensure(@id, @uri)
      assert Registry.count(Download.Registry) == 1

      await(:done)
    end

    test "a call that finds a download already finished gives the path of the cache" do
      serve("the audio")
      start()
      await(:done)

      assert {:ok, %{complete?: true}} = Download.ensure(@id, @uri)
    end

    test "it gives both names, because the file moves when it is whole" do
      serve("the audio")

      assert {:ok, %{paths: [cache_path, partial_path], complete?: false}} =
               Download.ensure(@id, @uri)

      assert cache_path == Path.join([Cache.directory(), Download.namespace(), @id])
      assert partial_path == Path.join(Download.directory(), @id)
    end
  end

  describe "a read that fails" do
    test "a status that is not 200 tells the watcher and holds no entry" do
      serve("go away", status: 403)
      start()

      await({:error, {:unexpected_status, 403}})

      assert {:error, _reason} = Cache.fetch(Download.namespace(), @id)
    end

    test "a body shorter than the length of the answer holds no entry" do
      serve("short", headers: [{"content-length", "99"}])
      start()

      await({:error, {:short_read, 99, 5}})

      assert {:error, _reason} = Cache.fetch(Download.namespace(), @id)
    end

    test "the bytes that arrived stay, so a later play asks for the rest" do
      serve("short", headers: [{"content-length", "99"}])
      start()
      await({:error, {:short_read, 99, 5}})

      assert File.read!(Path.join(Download.directory(), @id)) == "short"
    end
  end

  describe "a read that continues" do
    setup do
      File.mkdir_p!(Download.directory())
      File.write!(Path.join(Download.directory(), @id), "first half ")
      :ok
    end

    test "it asks for the bytes that it does not hold" do
      Req.Test.stub(Download, fn conn ->
        assert Plug.Conn.get_req_header(conn, "range") == ["bytes=11-"]

        conn
        |> Plug.Conn.put_resp_header("content-range", "bytes 11-21/22")
        |> Plug.Conn.send_resp(206, "second half")
      end)

      start()
      await(:done)

      assert {:ok, entry} = Cache.fetch(Download.namespace(), @id)
      assert File.read!(Path.join(Cache.directory(), entry.key)) == "first half second half"
      assert entry.byte_size == 22
    end

    test "a server that gives the whole file writes the file again" do
      serve("the whole thing", status: 200)

      start()
      await(:done)

      assert {:ok, entry} = Cache.fetch(Download.namespace(), @id)
      assert File.read!(Path.join(Cache.directory(), entry.key)) == "the whole thing"
      assert entry.byte_size == 15
    end
  end

  describe "sweep" do
    test "it removes a partial file that no download continues" do
      File.mkdir_p!(Download.directory())
      path = Path.join(Download.directory(), "old")
      File.write!(path, "abandoned")
      old = DateTime.utc_now() |> DateTime.add(-2, :day) |> DateTime.to_unix()
      File.touch!(path, old)

      assert Download.sweep() == 1
      refute File.exists?(path)
    end

    test "it keeps a partial file of this hour, because a play continues it" do
      File.mkdir_p!(Download.directory())
      path = Path.join(Download.directory(), "new")
      File.write!(path, "half of it")

      assert Download.sweep() == 0
      assert File.exists?(path)
    end

    test "a directory that holds nothing gives nothing" do
      assert Download.sweep() == 0
    end
  end
end
