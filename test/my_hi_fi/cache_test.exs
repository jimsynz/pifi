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

  # What `MyHiFi.Artwork` writes for a thumbnail: an entry that names its source.
  defp thumbnail_of(source, bytes \\ "a thumbnail") do
    put(source.namespace, source.entry_key <> ".thumbnail", bytes, %{
      variant_of_blob_id: source.id,
      variant_name: "thumbnail",
      variant_digest: "0123456789abcdef"
    })
  end

  # `MyHiFi.Device.Monitor` is the one subscriber, and it is a target module, so this
  # tests the wire that carries the notification to it. Free space moves when the cache
  # writes and when it removes, and a page shows that figure. See `MyHiFi.Cache.Entry`.
  describe "what the cache tells the rest of the firmware" do
    setup do
      :ok = Phoenix.PubSub.subscribe(MyHiFi.PubSub, "cache_entry:written")
    end

    test "a write publishes" do
      entry = put("artwork", "abc123", "hello world")

      assert_receive %Ash.Notifier.Notification{action: %{name: :put}, data: %{id: id}}
      assert id == entry.id
    end

    test "a removal publishes" do
      entry = put("artwork", "abc123", "hello world")
      assert_receive %Ash.Notifier.Notification{action: %{type: :create}}

      Cache.purge!(entry)

      assert_receive %Ash.Notifier.Notification{action: %{type: :destroy}}
    end
  end

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

  describe "the names that a caller may use" do
    # The namespace and the key become the path of a file, so a caller that could
    # name a parent directory could write anywhere on the partition.
    test "a key that names a parent directory is refused" do
      assert {:error, _reason} = Cache.put("artwork", "../../etc/passwd", %{bytes: "x"})
      assert {:error, _reason} = Cache.put("artwork", "..", %{bytes: "x"})
      assert {:error, _reason} = Cache.put("artwork", "a/b", %{bytes: "x"})
      assert keys() == []
    end

    test "a namespace that names a parent directory is refused" do
      assert {:error, _reason} = Cache.put("../../etc", "passwd", %{bytes: "x"})
      assert {:error, _reason} = Cache.put("a/b", "key", %{bytes: "x"})
      assert keys() == []
    end

    test "a hash and an identifier are both names that a caller may use" do
      assert {:ok, _entry} = Cache.put("artwork", String.duplicate("a", 64), %{bytes: "x"})
      assert {:ok, _entry} = Cache.put("download", Ash.UUID.generate(), %{bytes: "x"})
      assert {:ok, _entry} = Cache.put("artwork", "abc123.jpg", %{bytes: "x"})
    end
  end

  describe "put_file" do
    # The file must sit on the partition that holds the cache, because the action
    # moves it and a move across two partitions gives `:exdev`. A caller of this
    # action builds its path from the same place, so this test does the same.
    setup do
      directory = Path.join(Path.dirname(Cache.directory()), "partial_test")
      File.mkdir_p!(directory)
      on_exit(fn -> File.rm_rf(directory) end)

      {:ok, path: Path.join(directory, "episode_#{System.unique_integer([:positive])}")}
    end

    test "it moves the file into the cache and holds its size", %{path: path} do
      File.write!(path, "the whole episode")

      entry = Cache.put_file!("download", "episode", %{path: path, content_type: "audio/mpeg"})

      assert entry.namespace == "download"
      assert entry.byte_size == 17
      assert entry.content_type == "audio/mpeg"
      assert File.read!(on_disk(entry)) == "the whole episode"
    end

    test "the file it moved is gone from where it was", %{path: path} do
      File.write!(path, "audio")

      Cache.put_file!("download", "episode", %{path: path})

      refute File.exists?(path)
    end

    test "it holds no checksum, because no reader of this firmware asks for one", %{path: path} do
      File.write!(path, "audio")

      entry = Cache.put_file!("download", "episode", %{path: path})

      assert entry.checksum == nil
    end

    test "a caller marks an entry to keep as it moves it", %{path: path} do
      File.write!(path, "audio")

      entry = Cache.put_file!("download", "episode", %{path: path, keep?: true})

      assert entry.keep? == true
    end

    test "a path that names no file adds no row", %{path: path} do
      assert {:error, _reason} = Cache.put_file("download", "episode", %{path: path})
      assert keys() == []
    end

    test "the same key twice holds one entry", %{path: path} do
      File.write!(path, "first")
      Cache.put_file!("download", "episode", %{path: path})

      File.write!(path, "second time")
      entry = Cache.put_file!("download", "episode", %{path: path})

      assert keys() == ["episode"]
      assert entry.byte_size == 11
      assert File.read!(on_disk(entry)) == "second time"
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

  describe "a variant of an entry" do
    test "it is an entry of its own, and the source names it" do
      source = put("artwork", "abc123", "a picture")
      variant = thumbnail_of(source)

      assert variant.key == "artwork/abc123.thumbnail"
      assert File.exists?(on_disk(variant))
      assert [found] = Ash.load!(source, :variants).variants
      assert found.id == variant.id
    end

    # The database holds a foreign key on `variant_of_blob_id`, so a purge of the
    # source alone fails and the cache then frees nothing.
    test "a purge of the source takes it, and its file" do
      source = put("artwork", "abc123", "a picture")
      variant = thumbnail_of(source)

      assert :ok = Cache.purge(source)

      assert Cache.list_entries!() == []
      refute File.exists?(on_disk(variant))
    end

    test "an eviction that takes the source takes it as well" do
      source = put("artwork", "abc123", String.duplicate("x", 100))
      variant = thumbnail_of(source)

      # The source alone covers the excess, so the eviction chooses it and not the
      # variant, which is smaller and warmer.
      Application.put_env(:my_hi_fi, :cache_limit, 50)

      assert {:ok, report} = Cache.prune()

      assert report.removed == 1
      assert keys() == []
      refute File.exists?(on_disk(variant))
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

    # The loop that one measure makes: `MyHiFi.Artwork` touches a picture each time
    # that it draws a list, so a picture is always warm and the audio of an album that
    # a person marked and did not play is always cold. The eviction took the album, the
    # next sync read it again, and moving through a list of covers wrote the card.
    test "it takes the lightest first, though the heavier entry is colder" do
      audio = put("download", "audio", String.duplicate("x", 400), %{weight: 1})
      put("artwork", "picture", String.duplicate("x", 400))

      # The audio is the colder of the two, and the picture is warm because a list
      # was drawn a moment ago.
      Cache.touch!(audio)
      Process.sleep(5)
      Cache.touch!(Cache.fetch!("artwork", "picture"))

      Application.put_env(:my_hi_fi, :cache_limit, 500)

      assert {:ok, report} = Cache.prune()

      assert report.removed == 1
      assert keys() == ["audio"]
    end

    test "two entries of one weight go by the time, as before" do
      cold = put("download", "cold", String.duplicate("x", 400), %{weight: 1})
      put("download", "warm", String.duplicate("x", 400), %{weight: 1})

      Cache.touch!(cold)
      Process.sleep(5)
      Cache.touch!(Cache.fetch!("download", "warm"))

      Application.put_env(:my_hi_fi, :cache_limit, 500)

      assert {:ok, _report} = Cache.prune()

      assert keys() == ["warm"]
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

    # **What the cache already holds is a part of the space that it may hold.** The
    # free space of a partition is what is free now, and the files of the cache are not
    # free, so a rule that read that number alone shrank its own ceiling with every
    # file that it wrote and the cache stopped at half of what it may have. A board on
    # 2026-09-14 gave 5,981 MB where 11,924 MB was free for it.
    # **The free space comes from a setting here, and not from `df`.** This test reads
    # the limit, writes a file, and reads the limit again, and `df` measures a machine
    # that another program is also writing. A build agent that wrote 12 KB in that
    # moment failed this test, and the rule that it covers was correct.
    test "it grows by what the cache already holds" do
      Application.delete_env(:my_hi_fi, :cache_limit)
      Application.put_env(:my_hi_fi, :cache_free_bytes, 2 * 1024 * 1024 * 1024)
      on_exit(fn -> Application.delete_env(:my_hi_fi, :cache_free_bytes) end)

      empty = Cache.limit()

      # The file must sit on the partition that holds the cache, or the move gives
      # `:exdev`, in the way that the setup of `put_file` says.
      directory = Path.join(Path.dirname(Cache.directory()), "limit_test")

      File.mkdir_p!(directory)
      on_exit(fn -> File.rm_rf(directory) end)
      path = Path.join(directory, "episode")
      File.write!(path, String.duplicate("a", 4096))

      Cache.put_file!("download", "episode", %{path: path, content_type: "audio/mpeg"})

      assert Cache.bytes() == 4096
      assert Cache.limit() == empty + 4096
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
    # A show and an episode are both `MyHiFi.Playback.Item` now, and `"item"` is the
    # one record type that the catalogue attaches under.
    setup do
      show =
        MyHiFi.Playback.upsert_item!(%{
          source: "podcasts",
          source_ref: "https://a.test/rss",
          kind: :container,
          title: "A show"
        })

      {:ok, show: show}
    end

    test "one entry serves many records, and it holds one file", %{show: show} do
      cover = put("artwork", "shared", String.duplicate("c", 400))

      {:ok, _} = Cache.attach(%{entry_id: cover.id, record_type: "item", record_id: show.id})

      episode_ids =
        for number <- 1..5 do
          episode =
            MyHiFi.Playback.upsert_item!(%{
              source: "podcasts",
              source_ref: "https://a.test/rss e#{number}",
              kind: :track,
              parent_id: show.id,
              title: "Episode #{number}",
              url: "https://a.test/#{number}.mp3"
            })

          {:ok, _} =
            Cache.attach(%{entry_id: cover.id, record_type: "item", record_id: episode.id})

          episode.id
        end

      # Six records name one picture, and the disk holds it once.
      assert length(Cache.list_entries!()) == 1
      assert length(Ash.read!(Cache.Attachment)) == 6
      assert length(held_files()) == 1

      assert Cache.usage_of("item", show.id) == %{count: 1, bytes: 400}
      assert Cache.usage_of("item", hd(episode_ids)) == %{count: 1, bytes: 400}
    end

    test "saying it twice writes one row", %{show: show} do
      entry = put("artwork", "a", "x")

      {:ok, first} = Cache.attach(%{entry_id: entry.id, record_type: "item", record_id: show.id})
      {:ok, second} = Cache.attach(%{entry_id: entry.id, record_type: "item", record_id: show.id})

      assert second.id == first.id
      assert length(Ash.read!(Cache.Attachment)) == 1
    end

    test "a record reads its entries through the join", %{show: show} do
      entry = put("artwork", "a", "x")
      {:ok, _} = Cache.attach(%{entry_id: entry.id, record_type: "item", record_id: show.id})

      loaded = Ash.load!(show, [:cached_files, :cache_attachments])

      assert Enum.map(loaded.cached_files, & &1.id) == [entry.id]
      assert length(loaded.cache_attachments) == 1
    end

    test "a record of another type is not this record", %{show: show} do
      entry = put("artwork", "a", "x")
      # The identifier is the same, and the type is not.
      {:ok, _} = Cache.attach(%{entry_id: entry.id, record_type: "episode", record_id: show.id})

      assert Ash.load!(show, :cached_files).cached_files == []
      assert Cache.usage_of("item", show.id) == %{count: 0, bytes: 0}
      assert Cache.usage_of("episode", show.id) == %{count: 1, bytes: 1}
    end

    test "an eviction takes the join rows with the entry", %{show: show} do
      entry = put("artwork", "a", String.duplicate("x", 800))
      {:ok, _} = Cache.attach(%{entry_id: entry.id, record_type: "item", record_id: show.id})

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
      {:ok, _} = Cache.attach(%{entry_id: entry.id, record_type: "item", record_id: show.id})

      assert :ok = MyHiFi.Playback.destroy_item(show)

      assert Ash.read!(Cache.Attachment) == []
    end

    test "a host that goes leaves the entry, because another record may name it", %{show: show} do
      other =
        MyHiFi.Playback.upsert_item!(%{
          source: "podcasts",
          source_ref: "https://b.test/rss",
          kind: :container,
          title: "Another show"
        })

      # One picture, named by two shows.
      entry = put("artwork", "shared", "x")
      {:ok, _} = Cache.attach(%{entry_id: entry.id, record_type: "item", record_id: show.id})
      {:ok, _} = Cache.attach(%{entry_id: entry.id, record_type: "item", record_id: other.id})

      assert :ok = MyHiFi.Playback.destroy_item(show)

      # A cascade to the entries would have taken the picture that `other` still uses.
      assert Cache.usage_of("item", other.id) == %{count: 1, bytes: 1}
      assert File.exists?(on_disk(entry))
    end

    test "an entry that no record names any more waits for the eviction", %{show: show} do
      entry = put("artwork", "a", String.duplicate("x", 800))
      {:ok, _} = Cache.attach(%{entry_id: entry.id, record_type: "item", record_id: show.id})

      assert :ok = MyHiFi.Playback.destroy_item(show)

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
        MyHiFi.Playback.upsert_item!(%{
          source: "podcasts",
          source_ref: "https://a.test/rss one",
          kind: :track,
          parent_id: show.id,
          title: "An episode",
          url: "https://a.test/1.mp3"
        })

      {:ok, _} = Cache.attach(%{entry_id: entry.id, record_type: "item", record_id: show.id})

      {:ok, _} =
        Cache.attach(%{entry_id: entry.id, record_type: "item", record_id: episode.id})

      assert :ok = MyHiFi.Playback.destroy_item(episode)

      assert Cache.usage_of("item", episode.id) == %{count: 0, bytes: 0}
      assert Cache.usage_of("item", show.id) == %{count: 1, bytes: 1}
    end

    test "a purge takes the join rows with the entry", %{show: show} do
      entry = put("artwork", "a", "x")
      {:ok, _} = Cache.attach(%{entry_id: entry.id, record_type: "item", record_id: show.id})

      assert :ok = Cache.purge(entry)

      assert Ash.read!(Cache.Attachment) == []
    end
  end
end
