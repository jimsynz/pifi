defmodule PiFi.Player.DownloadTest do
  use PiFi.DataCase, async: false

  alias PiFi.Cache
  alias PiFi.Event
  alias PiFi.Event.Source, as: Events
  alias PiFi.Player.Download

  @id "episode-1"
  @uri "https://example.test/episode.mp3"

  setup do
    Application.put_env(:pifi, Download, plug: {Req.Test, Download}, retry: false)

    # **The wait between attempts is real time, and it is set for the whole file.** It
    # used to be set inside one describe block and cleared when that block ended, so a
    # download still asking again took the production wait of two seconds a step — and
    # outlived the drain below, into the next test, where its requests answered that
    # test's stub. Two tests failed that way in CI.
    Application.put_env(:pifi, :download_backoff_ms, 10)

    Req.Test.set_req_test_from_context(%{async: false})

    clean = fn ->
      File.rm_rf(Cache.directory())
      File.rm_rf(Download.directory())
    end

    clean.()

    on_exit(fn ->
      drained()
      Application.delete_env(:pifi, Download)
      Application.delete_env(:pifi, :download_backoff_ms)
      clean.()
    end)

    :ok
  end

  # **A download outlives the test that started it**, because it answers its watchers
  # before it stops and because a read that was refused waits and asks again. A process
  # left over from one test is the process that the next one joins, and the requests it
  # makes are counted against that test. Two tests here failed that way, and only in a
  # full run.
  # **It waits and it does not kill.** The request runs in a process of its own that
  # nothing links to, so a download that is killed leaves that request in flight, and it
  # answers the stub of whichever test is running by then. A download that stops of its
  # own accord has already had its answer.
  defp drained(tries \\ 400)

  defp drained(0) do
    flunk("a download was still running when the test ended")
  end

  defp drained(tries) do
    case Registry.lookup(PiFi.Player.Download.Registry, @id) do
      [] ->
        :ok

      _running ->
        Process.sleep(5)
        drained(tries - 1)
    end
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

      # **It reads the process of this episode and not the count of every download.** A
      # download left running by an earlier test makes that count 2 or 3, and says
      # nothing about whether this call started a second one. CI read 3.
      assert {:ok, _first} = Download.ensure(@id, @uri)
      assert [{holder, _value}] = Registry.lookup(Download.Registry, @id)
      assert {:ok, _second} = Download.ensure(@id, @uri)
      assert [{^holder, _value}] = Registry.lookup(Download.Registry, @id)

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

  describe "what a page hears" do
    # **A page draws a share of a number that a person reads, and a watcher needs every
    # count.** The download writes about one message for each 16 KB, so a page that drew
    # itself again for each one would spend the board on a figure that moves too fast to
    # see. See `PiFi.Event.Source.AudioChanged`.
    test "the audio of an item arriving reaches the source topic" do
      Event.subscribe(:source)
      serve("the audio")
      start()

      await(:done)

      assert_receive %Events.AudioChanged{item_id: @id, state: :held}
    end

    test "a read that fails says that the device holds nothing" do
      Event.subscribe(:source)
      serve("go away", status: 403)
      start()

      await({:error, {:unexpected_status, 403}})

      assert_receive %Events.AudioChanged{item_id: @id, state: :absent}
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

  # **A Plex server closes a connection when it has too many at once**, and this device
  # gives it several: a person plays a track while a mark reads a whole discography. The
  # read of the track died for that, and the pipeline with it, so the music stopped.
  describe "a connection that closes part way" do
    # **Each attempt runs in a process of its own**, because the request is spawned, so
    # the count of them lives outside all of them.
    #
    # The request that resumes from part of a file is what `a read that continues`
    # covers. This one is about the asking again at all: the read used to end here and
    # take the pipeline with it.
    test "it asks again, and the file ends up whole" do
      attempts = :counters.new(1, [])
      test = self()

      Req.Test.stub(Download, fn conn ->
        send(test, :asked)

        case :counters.get(attempts, 1) do
          0 ->
            :counters.add(attempts, 1, 1)
            Req.Test.transport_error(conn, :closed)

          _later ->
            Plug.Conn.send_resp(conn, 200, "the whole thing")
        end
      end)

      start()
      await(:done, 5_000)

      assert asks() == 2

      assert {:ok, entry} = Cache.fetch(Download.namespace(), @id)
      assert File.read!(Path.join(Cache.directory(), entry.key)) == "the whole thing"
    end

    # **A fault that is about the thing and not the connection gives the same answer
    # however many times it is asked**, so asking again only makes a person wait.
    test "a status that this device did not expect is not asked again" do
      test = self()

      Req.Test.stub(Download, fn conn ->
        send(test, :asked)
        Plug.Conn.send_resp(conn, 403, "go away")
      end)

      start()
      await({:error, {:unexpected_status, 403}})

      assert_received :asked
      refute_received :asked
    end

    test "it gives up rather than asking for ever" do
      test = self()

      Req.Test.stub(Download, fn conn ->
        send(test, :asked)
        Req.Test.transport_error(conn, :closed)
      end)

      start()
      await({:error, %Req.TransportError{reason: :closed}}, 5_000)

      assert asks() <= 5
    end
  end

  defp asks(counted \\ 0) do
    receive do
      :asked -> asks(counted + 1)
    after
      0 -> counted
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
