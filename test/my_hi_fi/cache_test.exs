defmodule MyHiFi.CacheTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Cache

  setup do
    Application.put_env(:my_hi_fi, Cache, plug: {Req.Test, Cache}, retry: false)
    on_exit(fn -> Application.delete_env(:my_hi_fi, Cache) end)
    File.rm_rf(Cache.directory())

    on_exit(fn ->
      File.rm_rf(Cache.directory())
      Application.delete_env(:my_hi_fi, :cache_limit)
    end)

    :ok
  end

  defp put(namespace, key, bytes, options \\ %{}) do
    Cache.put!(
      namespace,
      key,
      Map.merge(%{bytes: bytes, content_type: "image/png"}, options)
    )
  end

  defp on_disk(entry), do: Path.join(Cache.directory(), entry.key)

  defp keys, do: Cache.list_entries!() |> Enum.map(& &1.entry_key) |> Enum.sort()

  defp held_files do
    Cache.directory() |> Path.join("**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1)
  end

  describe "put" do
    test "it writes the bytes and holds what they are" do
      entry = put("artwork", "abc123", "hello world")

      assert entry.namespace == "artwork"
      assert entry.entry_key == "abc123"
      assert entry.byte_size == 11
      assert entry.content_type == "image/png"
      assert entry.keep? == false
      assert entry.last_accessed_at
      assert File.read!(on_disk(entry)) == "hello world"
    end

    test "the key of the file holds the namespace, so a caller needs no prefix" do
      entry = put("artwork", "abc123", "x")

      assert entry.key == "artwork/abc123"
      assert Path.basename(Path.dirname(on_disk(entry))) == "artwork"
    end

    test "it holds a checksum of the bytes" do
      entry = put("artwork", "abc123", "hello world")

      assert entry.checksum == Base.encode64(:crypto.hash(:md5, "hello world"))
    end

    test "the same namespace and key write again over the same row and the same file" do
      first = put("artwork", "abc123", "one")
      second = put("artwork", "abc123", "two hundred")

      assert second.id == first.id
      assert second.byte_size == 11
      assert length(Cache.list_entries!()) == 1
      assert File.read!(on_disk(second)) == "two hundred"
    end

    test "two namespaces hold the same key and different things" do
      artwork = put("artwork", "same", "a picture")
      download = put("download", "same", "some audio")

      refute artwork.id == download.id
      assert File.read!(on_disk(artwork)) == "a picture"
      assert File.read!(on_disk(download)) == "some audio"
    end

    test "a caller marks an entry to keep as it writes it" do
      entry = put("download", "episode", "audio", %{keep?: true})

      assert entry.keep? == true
    end
  end

  describe "fetch" do
    test "it reads one entry of one namespace" do
      entry = put("artwork", "abc123", "x")

      assert {:ok, found} = Cache.fetch("artwork", "abc123")
      assert found.id == entry.id
    end

    test "a key of another namespace is absent" do
      put("artwork", "abc123", "x")

      assert {:error, _reason} = Cache.fetch("download", "abc123")
    end

    test "a key that nothing holds is absent" do
      assert {:error, _reason} = Cache.fetch("artwork", "nothing")
    end
  end

  describe "touch" do
    test "it moves the time that the eviction reads" do
      entry = put("artwork", "abc123", "x")
      before = entry.last_accessed_at

      Process.sleep(5)
      assert {:ok, touched} = Cache.touch(entry)

      assert DateTime.compare(touched.last_accessed_at, before) == :gt
    end
  end

  describe "keep and release" do
    test "a caller holds an entry against an eviction, and lets it go again" do
      entry = put("artwork", "abc123", "x")

      assert {:ok, kept} = Cache.keep(entry)
      assert kept.keep? == true

      assert {:ok, released} = Cache.release(kept)
      assert released.keep? == false
    end
  end

  describe "purge" do
    test "it removes the row and the file together" do
      entry = put("artwork", "abc123", "x")
      path = on_disk(entry)
      assert File.exists?(path)

      assert :ok = Cache.purge(entry)

      assert Cache.list_entries!() == []
      refute File.exists?(path)
    end
  end

  describe "prune" do
    test "a cache inside its limit loses nothing" do
      put("artwork", "a", String.duplicate("x", 100))
      Application.put_env(:my_hi_fi, :cache_limit, 1000)

      assert {:ok, report} = Cache.prune()

      assert report.removed == 0
      assert report.over? == false
      assert keys() == ["a"]
    end

    test "it removes the least recently used first" do
      cold = put("artwork", "cold", String.duplicate("x", 400))
      warm = put("artwork", "warm", String.duplicate("x", 400))
      hot = put("artwork", "hot", String.duplicate("x", 400))

      # The order of the writes is not the order of the use.
      for entry <- [hot, cold, warm], do: Process.sleep(5) && Cache.touch!(entry)
      Process.sleep(5)
      Cache.touch!(hot)

      Application.put_env(:my_hi_fi, :cache_limit, 900)

      assert {:ok, report} = Cache.prune()

      assert report.removed == 1
      # `cold` was used the longest ago of the three.
      assert keys() == ["hot", "warm"]
    end

    test "an entry to keep survives, whatever its age" do
      kept = put("download", "kept", String.duplicate("x", 800))
      Cache.keep!(kept)
      put("artwork", "cold", String.duplicate("x", 400))

      Application.put_env(:my_hi_fi, :cache_limit, 500)

      assert {:ok, _report} = Cache.prune()

      assert keys() == ["kept"]
    end

    test "a cache of nothing but entries to keep says that it is over its limit" do
      kept = put("download", "kept", String.duplicate("x", 900))
      Cache.keep!(kept)

      Application.put_env(:my_hi_fi, :cache_limit, 100)

      assert {:ok, report} = Cache.prune()

      # It reports the state and it removes nothing. The caller that marked the
      # entry is the one that can release it.
      assert report.removed == 0
      assert report.over? == true
      assert keys() == ["kept"]
    end

    test "it removes the file of each entry that it takes" do
      cold = put("artwork", "cold", String.duplicate("x", 800))
      path = on_disk(cold)

      Application.put_env(:my_hi_fi, :cache_limit, 100)
      assert {:ok, _report} = Cache.prune()

      refute File.exists?(path)
    end
  end

  describe "the limit" do
    test "it is the free space of the partition, less the reserve" do
      # No test value is set here, so this reads the real rule.
      assert is_integer(Cache.limit())
      assert Cache.limit() >= 0
    end

    test "a test may name a limit of its own" do
      Application.put_env(:my_hi_fi, :cache_limit, 4242)

      assert Cache.limit() == 4242
    end
  end

  describe "entries_in" do
    test "it reads one namespace, the most recently used first" do
      put("artwork", "a", "x")
      put("download", "b", "x")
      older = put("artwork", "c", "x")
      Process.sleep(5)
      Cache.touch!(older)

      assert Cache.entries_in!("artwork") |> Enum.map(& &1.entry_key) == ["c", "a"]
    end
  end

  describe "put_from_url" do
    defp serve(body, options \\ []) do
      status = Keyword.get(options, :status, 200)
      type = Keyword.get(options, :content_type, "image/png")

      Req.Test.stub(Cache, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type(type)
        |> Plug.Conn.send_resp(status, body)
      end)
    end

    test "it reads an address and holds what it gives" do
      serve("a picture")

      assert {:ok, entry} = Cache.put_from_url("artwork", %{url: "https://example.test/a.png"})

      assert entry.namespace == "artwork"
      assert entry.byte_size == 9
      assert entry.content_type == "image/png"
      assert File.read!(on_disk(entry)) == "a picture"
    end

    test "the key becomes the hash of the address" do
      serve("a picture")
      url = "https://example.test/a.png"

      assert {:ok, entry} = Cache.put_from_url("artwork", %{url: url})

      assert entry.entry_key == Base.encode16(:crypto.hash(:sha256, url), case: :lower)
    end

    test "a caller may name its own key" do
      serve("a picture")

      assert {:ok, entry} =
               Cache.put_from_url("artwork", %{
                 url: "https://example.test/a.png",
                 entry_key: "mine"
               })

      assert entry.entry_key == "mine"
    end

    test "the same address twice writes one row" do
      serve("a picture")
      url = "https://example.test/a.png"

      assert {:ok, first} = Cache.put_from_url("artwork", %{url: url})
      assert {:ok, second} = Cache.put_from_url("artwork", %{url: url})

      assert second.id == first.id
      assert length(Cache.list_entries!()) == 1
    end

    test "it removes the parameters from the type of the header" do
      serve("a picture", content_type: "image/jpeg; charset=binary")

      assert {:ok, entry} = Cache.put_from_url("artwork", %{url: "https://example.test/a.jpg"})

      assert entry.content_type == "image/jpeg"
    end

    test "a type that a caller names wins over the header" do
      serve("a picture", content_type: "application/octet-stream")

      assert {:ok, entry} =
               Cache.put_from_url("artwork", %{
                 url: "https://example.test/a.png",
                 content_type: "image/png"
               })

      assert entry.content_type == "image/png"
    end

    test "a body above the limit is refused, and it writes nothing" do
      serve(String.duplicate("x", 500))

      assert {:error, _reason} =
               Cache.put_from_url("artwork", %{url: "https://example.test/a.png", max_bytes: 100})

      assert Cache.list_entries!() == []
      refute File.exists?(Path.join(Cache.directory(), "artwork"))
    end

    test "an address that gives an error writes nothing" do
      serve("no", status: 404)

      assert {:error, _reason} =
               Cache.put_from_url("artwork", %{url: "https://example.test/a.png"})

      assert Cache.list_entries!() == []
    end

    test "a fault of the network writes nothing" do
      Req.Test.stub(Cache, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, _reason} =
               Cache.put_from_url("artwork", %{url: "https://example.test/a.png"})

      assert Cache.list_entries!() == []
    end
  end

  describe "purge_all" do
    test "it removes every entry that a query names, and each file" do
      require Ash.Query

      artwork = put("artwork", "a", "x")
      other = put("artwork", "b", "y")
      download = put("download", "c", "z")

      assert :ok =
               Cache.Entry
               |> Ash.Query.filter(namespace == "artwork")
               |> Cache.purge_all()

      assert keys() == ["c"]
      refute File.exists?(on_disk(artwork))
      refute File.exists?(on_disk(other))
      assert File.exists?(on_disk(download))
    end

    test "a query that names nothing removes nothing" do
      require Ash.Query

      put("artwork", "a", "x")

      assert :ok =
               Cache.Entry
               |> Ash.Query.filter(namespace == "nothing")
               |> Cache.purge_all()

      assert keys() == ["a"]
    end
  end

  describe "attachments" do
    setup do
      show =
        MyHiFi.Podcast.upsert_show_from_feed!(%{
          feed_url: "https://a.test/rss",
          title: "A show"
        })

      {:ok, show: show}
    end

    test "one entry serves many records, and it holds one file", %{show: show} do
      cover = put("artwork", "shared", String.duplicate("c", 400))

      {:ok, _} = Cache.attach(%{entry_id: cover.id, record_type: "show", record_id: show.id})

      episode_ids =
        for number <- 1..5 do
          episode =
            MyHiFi.Podcast.upsert_episode_from_feed!(%{
              show_id: show.id,
              guid: "e#{number}",
              audio_url: "https://a.test/#{number}.mp3"
            })

          {:ok, _} =
            Cache.attach(%{entry_id: cover.id, record_type: "episode", record_id: episode.id})

          episode.id
        end

      # Six records name one picture, and the disk holds it once.
      assert length(Cache.list_entries!()) == 1
      assert length(Ash.read!(Cache.Attachment)) == 6
      assert length(held_files()) == 1

      assert Cache.usage_of("show", show.id) == %{count: 1, bytes: 400}
      assert Cache.usage_of("episode", hd(episode_ids)) == %{count: 1, bytes: 400}
    end

    test "saying it twice writes one row", %{show: show} do
      entry = put("artwork", "a", "x")

      {:ok, first} = Cache.attach(%{entry_id: entry.id, record_type: "show", record_id: show.id})
      {:ok, second} = Cache.attach(%{entry_id: entry.id, record_type: "show", record_id: show.id})

      assert second.id == first.id
      assert length(Ash.read!(Cache.Attachment)) == 1
    end

    test "a record reads its entries through the join", %{show: show} do
      entry = put("artwork", "a", "x")
      {:ok, _} = Cache.attach(%{entry_id: entry.id, record_type: "show", record_id: show.id})

      loaded = Ash.load!(show, [:cached_files, :cache_attachments])

      assert Enum.map(loaded.cached_files, & &1.id) == [entry.id]
      assert length(loaded.cache_attachments) == 1
    end

    test "a record of another type is not this record", %{show: show} do
      entry = put("artwork", "a", "x")
      # The identifier is the same, and the type is not.
      {:ok, _} = Cache.attach(%{entry_id: entry.id, record_type: "episode", record_id: show.id})

      assert Ash.load!(show, :cached_files).cached_files == []
      assert Cache.usage_of("show", show.id) == %{count: 0, bytes: 0}
      assert Cache.usage_of("episode", show.id) == %{count: 1, bytes: 1}
    end

    test "an eviction takes the join rows with the entry", %{show: show} do
      entry = put("artwork", "a", String.duplicate("x", 800))
      {:ok, _} = Cache.attach(%{entry_id: entry.id, record_type: "show", record_id: show.id})

      # A record that names a file must not hold it against an eviction, or the cache
      # would fill with entries that nothing may remove. The record keeps its address
      # and the next read fetches the file again.
      Application.put_env(:my_hi_fi, :cache_limit, 100)
      assert {:ok, report} = Cache.prune()

      assert report.removed == 1
      assert Cache.list_entries!() == []
      assert Ash.read!(Cache.Attachment) == []
    end

    test "a host that goes takes its own join rows", %{show: show} do
      entry = put("artwork", "a", "x")
      {:ok, _} = Cache.attach(%{entry_id: entry.id, record_type: "show", record_id: show.id})

      assert :ok = MyHiFi.Podcast.destroy_show(show)

      assert Ash.read!(Cache.Attachment) == []
    end

    test "a host that goes leaves the entry, because another record may name it", %{show: show} do
      other =
        MyHiFi.Podcast.upsert_show_from_feed!(%{
          feed_url: "https://b.test/rss",
          title: "Another show"
        })

      # One picture, named by two shows.
      entry = put("artwork", "shared", "x")
      {:ok, _} = Cache.attach(%{entry_id: entry.id, record_type: "show", record_id: show.id})
      {:ok, _} = Cache.attach(%{entry_id: entry.id, record_type: "show", record_id: other.id})

      assert :ok = MyHiFi.Podcast.destroy_show(show)

      # A cascade to the entries would have taken the picture that `other` still uses.
      assert Cache.usage_of("show", other.id) == %{count: 1, bytes: 1}
      assert File.exists?(on_disk(entry))
    end

    test "an entry that no record names any more waits for the eviction", %{show: show} do
      entry = put("artwork", "a", String.duplicate("x", 800))
      {:ok, _} = Cache.attach(%{entry_id: entry.id, record_type: "show", record_id: show.id})

      assert :ok = MyHiFi.Podcast.destroy_show(show)

      # Nothing names it, and it is still here: a cache reclaims when it needs the
      # room, and it is then the coldest thing to take.
      assert keys() == ["a"]

      Application.put_env(:my_hi_fi, :cache_limit, 100)
      assert {:ok, %{removed: 1}} = Cache.prune()
      assert keys() == []
    end

    test "an episode that goes takes its own rows and no other", %{show: show} do
      entry = put("artwork", "shared", "x")

      episode =
        MyHiFi.Podcast.upsert_episode_from_feed!(%{
          show_id: show.id,
          guid: "one",
          audio_url: "https://a.test/1.mp3"
        })

      {:ok, _} = Cache.attach(%{entry_id: entry.id, record_type: "show", record_id: show.id})

      {:ok, _} =
        Cache.attach(%{entry_id: entry.id, record_type: "episode", record_id: episode.id})

      assert :ok = MyHiFi.Podcast.destroy_episode(episode)

      assert Cache.usage_of("episode", episode.id) == %{count: 0, bytes: 0}
      assert Cache.usage_of("show", show.id) == %{count: 1, bytes: 1}
    end

    test "a purge takes the join rows with the entry", %{show: show} do
      entry = put("artwork", "a", "x")
      {:ok, _} = Cache.attach(%{entry_id: entry.id, record_type: "show", record_id: show.id})

      assert :ok = Cache.purge(entry)

      assert Ash.read!(Cache.Attachment) == []
    end
  end
end
