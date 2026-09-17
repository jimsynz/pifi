defmodule PiFi.Playback.FavouriteAudioTest do
  use PiFi.DataCase, async: false

  require Ash.Query
  use Oban.Testing, repo: PiFi.Repo

  alias PiFi.Cache
  alias PiFi.Jellyfin.Fill
  alias PiFi.Jellyfin.Server
  alias PiFi.Playback
  alias PiFi.Playback.FavouriteAudio
  alias PiFi.Player.Download
  alias PiFi.Podcast
  alias PiFi.Podcast.Fill, as: PodcastFill
  alias PiFi.Settings

  @worker PiFi.Playback.Item.Workers.CacheAudio

  setup do
    Application.put_env(:pifi, Download, plug: {Req.Test, Download}, retry: false)
    Application.put_env(:pifi, Server, plug: {Req.Test, Server}, retry: false)
    Req.Test.set_req_test_from_context(%{async: false})

    clean = fn ->
      File.rm_rf(Cache.directory())
      File.rm_rf(Download.directory())
    end

    clean.()

    on_exit(fn ->
      Application.delete_env(:pifi, Download)
      Application.delete_env(:pifi, Server)
      Application.delete_env(:pifi, :cache_limit)
      clean.()
    end)

    Settings.put!(Server.address_setting(), "http://jellyfin.test")
    Settings.put!(Server.token_setting(), "THETOKEN")
    Settings.put!(Server.user_setting(), "THEUSER")

    :ok
  end

  # The audio of every track, and the same number of bytes for each one, so a test
  # can count what the card holds.
  defp serve(bytes) do
    body = String.duplicate("x", bytes)

    Req.Test.stub(Download, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)
  end

  defp hold_episodes(count), do: Settings.put!("podcasts.hold_episodes", to_string(count))

  defp episodes_of(item) do
    PiFi.Playback.Item
    |> Ash.Query.filter(parent_id == ^item.id and kind == :track)
    |> Ash.Query.sort(published_at: :desc)
    |> Ash.read!()
  end

  defp artist(ref \\ "artist-1") do
    Fill.artists([%{ref: ref, title: "Massive Attack", parent_ref: nil, artwork_url: nil}])

    item(ref)
  end

  defp album_of(ref, title, published_at \\ nil) do
    %{
      ref: ref,
      title: title,
      parent_ref: "artist-1",
      artwork_url: nil,
      subtitle: nil,
      published_at: published_at
    }
  end

  defp album(ref \\ "album-1") do
    Fill.albums([
      %{ref: ref, title: "Mezzanine", parent_ref: nil, artwork_url: nil, subtitle: nil}
    ])

    item(ref)
  end

  defp track(ref, options \\ []) do
    Fill.tracks([
      %{
        ref: ref,
        title: "Track #{ref}",
        parent_ref: Keyword.get(options, :album, "album-1"),
        artwork_url: nil,
        subtitle: nil,
        duration_ms: Keyword.get(options, :duration_ms),
        byte_size: Keyword.get(options, :byte_size, 100),
        number: Keyword.get(options, :number),
        format: :flac
      }
    ])

    item(ref)
  end

  # A show is a container, and a person subscribes to it. Every episode of it keeps
  # its place.
  defp show do
    show = Podcast.upsert_show_from_feed!(%{feed_url: "https://example.test/rss"})
    item = PodcastFill.show(%{feed_url: "https://example.test/rss", title: "Road Work"})
    {:ok, _show} = Podcast.set_show_item(show, %{item_id: item.id})

    PodcastFill.episodes(item, "https://example.test/rss", [
      %{
        guid: "episode-1",
        title: "Episode 1",
        audio_url: "https://example.test/1.mp3",
        mime_type: "audio/mpeg",
        duration_ms: 100,
        published_at: nil,
        description: nil,
        artwork_url: nil
      }
    ])

    item
  end

  defp item(ref) do
    Enum.find(
      Playback.list_items!(),
      &(&1.source == Fill.source() and &1.source_ref == ref)
    )
  end

  defp held(track_id) do
    case Cache.fetch(Download.namespace(), track_id) do
      {:ok, entry} -> entry
      {:error, _reason} -> nil
    end
  end

  defp artwork(key, bytes) do
    Cache.put!("artwork", key, %{
      bytes: String.duplicate("x", bytes),
      content_type: "image/png"
    })
  end

  describe "the mark asks for the audio" do
    test "marking a track puts one job in the queue, and the control answers at once" do
      one = track("track-1")

      Req.Test.stub(Download, fn _conn -> raise "the network must not be read here" end)

      assert {:ok, marked} = Playback.set_favourite(one)

      assert marked.favourite? == true
      assert marked.favourited_at != nil
      assert_enqueued(worker: @worker)
    end

    test "the job reads the audio on to the card" do
      serve(100)
      one = track("track-1")

      {:ok, _item} = Playback.set_favourite(one)

      assert %{success: 1} = Oban.drain_queue(queue: :default)

      assert entry = held(one.id)
      assert entry.byte_size == 100
    end

    # An album holds tracks, so a mark on it reads every one of them.
    test "marking a container reads each track that it holds" do
      serve(100)
      one = album()
      first = track("track-1")
      second = track("track-2")

      assert FavouriteAudio.read(%{one | favourite?: true}) == 2

      assert held(first.id)
      assert held(second.id)
    end

    # **A mark reaches two levels.** An artist holds albums and no track of its own, so
    # a mark on one reads the tracks of each album. A discography is gigabytes, and a
    # person who marks one has said what they want the card for.
    test "marking an artist reads the tracks of each album that it holds" do
      serve(100)
      artist()
      Fill.albums([album_of("album-1", "Mezzanine"), album_of("album-2", "Blue Lines")])
      first = track("track-1", album: "album-1")
      second = track("track-2", album: "album-2")

      assert FavouriteAudio.read(item("artist-1")) == 2

      assert held(first.id)
      assert held(second.id)
    end

    # A run that reads album by album leaves whole albums on the card when it stops, and
    # not one track of each.
    test "it reads one album after the other, in the order of the albums" do
      serve(100)
      artist()

      Fill.albums([
        album_of("album-2", "Blue Lines", ~U[1991-04-08 00:00:00Z]),
        album_of("album-1", "Mezzanine", ~U[1998-04-20 00:00:00Z])
      ])

      first = track("track-1", album: "album-1", number: 1)
      second = track("track-2", album: "album-2", number: 1)

      assert [one, two] = FavouriteAudio.tracks(item("artist-1"))
      assert one.id == second.id
      assert two.id == first.id
    end

    # An album that holds tracks of its own reads those, and it reaches no further.
    test "an album reads its own tracks and not the tracks of a container below it" do
      serve(100)
      album()
      one = track("track-1")

      assert FavouriteAudio.read(item("album-1")) == 1
      assert held(one.id)
    end

    test "a track that the cache holds already reads nothing, and it touches nothing" do
      serve(100)
      one = track("track-1")

      assert FavouriteAudio.read(one) == 1
      before = held(one.id)

      Req.Test.stub(Download, fn _conn -> raise "the network must not be read again" end)

      assert FavouriteAudio.read(one) == 1
      # `touch` moves the time that the eviction reads, so a run that touched every
      # favourite would keep each one warm for ever.
      assert held(one.id).last_accessed_at == before.last_accessed_at
    end
  end

  # This is the judgement call of the feature, and `keeps_place?` is the fact that
  # makes it. A show holds hundreds of episodes, and writing all the time shortens the
  # life of the card.
  describe "a subscription to a podcast show" do
    test "marking a show reads nothing" do
      Req.Test.stub(Download, fn _conn -> raise "the network must not be read" end)

      assert FavouriteAudio.read(show()) == 0
    end

    # **A person who follows a show hears it away from the network.** The count of the
    # source says how many of the newest episodes the card holds, and 0 holds none.
    test "marking a show reads the newest episodes that a person has not played" do
      serve(100)
      item = show()

      {:ok, _marked} = Playback.set_favourite(item)

      assert %{success: 1} = Oban.drain_queue(queue: :default)

      episodes = episodes_of(item)

      refute episodes == [], "the show holds no episode to read"
      assert Enum.all?(episodes, &held(&1.id)), "an episode of the show is not on the card"
    end

    test "a count of none reads nothing, and it queues nothing that fails" do
      Req.Test.stub(Download, fn _conn -> raise "the network must not be read" end)
      hold_episodes(0)
      item = show()

      {:ok, _marked} = Playback.set_favourite(item)

      assert %{success: 1, cancelled: 0} = Oban.drain_queue(queue: :default)
      assert Enum.all?(episodes_of(item), &is_nil(held(&1.id)))
    end

    test "it reads no more than the count of the source" do
      serve(100)
      hold_episodes(1)
      item = show()

      assert length(FavouriteAudio.tracks(item)) == 1
    end

    # An episode that a person finished is one that they are done with, and its file was
    # released when it ended.
    test "it reads no episode that a person played" do
      serve(100)
      item = show()
      [newest | _rest] = episodes_of(item)
      {:ok, _played} = Playback.mark_played(newest)

      refute Enum.any?(FavouriteAudio.tracks(item), &(&1.id == newest.id))
    end

    test "marking one episode by itself puts no job in the queue either" do
      Req.Test.stub(Download, fn _conn -> raise "the network must not be read" end)
      show()

      episode =
        Enum.find(Playback.list_items!(), &(&1.source == "podcasts" and &1.kind == :track))

      {:ok, _marked} = Playback.set_favourite(episode)

      refute_enqueued(worker: @worker)
    end

    test "marking one episode by itself reads nothing either" do
      Req.Test.stub(Download, fn _conn -> raise "the network must not be read" end)
      show()

      episode =
        Enum.find(Playback.list_items!(), &(&1.source == "podcasts" and &1.kind == :track))

      assert episode.keeps_place? == true
      assert FavouriteAudio.read(episode) == 0
    end
  end

  # A live stream holds nothing to read, so a station that a person marked writes no
  # file.
  describe "a favourite radio station" do
    test "a station reads nothing, because its transport is not a file" do
      station =
        Playback.upsert_item!(%{
          source: "internet-radio",
          source_ref: "a-station",
          kind: :track,
          title: "RNZ National",
          url: "http://example.test/stream",
          transport: :http,
          format: :aac,
          live?: true
        })

      Req.Test.stub(Download, fn _conn -> raise "the network must not be read" end)

      assert FavouriteAudio.read(station) == 0
    end
  end

  describe "the file of a favourite is an ordinary entry of the cache" do
    test "a download that is complete holds no mark to keep, so an eviction can take it" do
      serve(100)
      one = track("track-1")

      assert FavouriteAudio.read(one) == 1

      # `PiFi.Player.Download` writes `keep?`, which is right while the file grows
      # and wrong for a file that only waits.
      assert held(one.id).keep? == false
    end

    # `PiFi.Player.Download.ensure/2` answers that a file is already whole when a
    # run joins the download of another run that ends while it joins. That answer
    # released nothing before, and the file then held `keep?` for ever.
    test "every track of a run ends with no mark to keep" do
      serve(100)
      one = album()
      Enum.each(["track-1", "track-2", "track-3"], &track/1)

      assert FavouriteAudio.read(%{one | favourite?: true}) == 3

      for entry <- Cache.entries_in!(Download.namespace()) do
        assert entry.keep? == false
      end
    end

    # A row that goes reaches neither the `:mark_played` action nor
    # `PiFi.Player.release_file/1`, so without this the file holds the card for ever
    # and nothing can name it again. See `PiFi.Jellyfin.Sync.Library`, which removes
    # the rows that a server no longer holds.
    test "a track that goes gives up its audio" do
      serve(100)
      one = track("track-1")
      FavouriteAudio.read(one)
      Cache.keep!(held(one.id))

      assert held(one.id).keep? == true

      :ok = Playback.destroy_item!(one)

      assert held(one.id).keep? == false
    end

    test "the ordinary eviction takes the file of a favourite" do
      serve(100)
      one = track("track-1")
      FavouriteAudio.read(one)

      Application.put_env(:pifi, :cache_limit, 10)

      assert {:ok, %{removed: 1}} = Cache.prune()
      assert held(one.id) == nil
    end
  end

  describe "removing the mark" do
    test "it releases the file, and it deletes nothing at once" do
      serve(100)
      one = track("track-1")
      {:ok, one} = Playback.set_favourite(one)
      Oban.drain_queue(queue: :default)

      # A file that a person is playing holds `keep?`, and this must give that up.
      Cache.keep!(held(one.id))
      assert held(one.id).keep? == true

      assert {:ok, cleared} = Playback.clear_favourite(one)

      assert cleared.favourite? == false
      assert cleared.favourited_at == nil
      # A person who changes their mind twice in a minute must not read the album
      # twice, so the file stays and the eviction decides.
      assert held(one.id).keep? == false
    end

    test "it releases each track of a container" do
      serve(100)
      one = album()
      first = track("track-1")
      second = track("track-2")

      FavouriteAudio.read(%{one | favourite?: true})
      Enum.each([first, second], &Cache.keep!(held(&1.id)))

      {:ok, marked} = Playback.set_favourite(one)
      {:ok, _cleared} = Playback.clear_favourite(marked)

      assert held(first.id).keep? == false
      assert held(second.id).keep? == false
    end
  end

  describe "how much the card holds" do
    test "a favourite that fits reads" do
      serve(100)
      Application.put_env(:pifi, :cache_limit, 250)
      one = track("track-1")

      assert FavouriteAudio.read(one) == 1
      assert held(one.id)
    end

    # Step two of the rule. `PiFi.Cache.prune/1` takes the coldest entries that no
    # `keep?` holds, and there is no eviction of its own here.
    test "a favourite that does not fit runs the ordinary eviction, and then reads" do
      serve(100)
      cold = artwork("cold", 400)
      Application.put_env(:pifi, :cache_limit, 250)

      # The cache is over its limit, so nothing is free until the eviction runs.
      assert Cache.free_bytes() == 0

      one = track("track-1")

      assert FavouriteAudio.read(one) == 1

      assert held(one.id)
      assert {:error, _reason} = Cache.fetch("artwork", cold.entry_key)
    end

    # Step three. The card is nominally full, and the run settles instead of writing
    # the card for ever.
    test "a favourite that does not fit after the eviction stops the run" do
      serve(100)
      Application.put_env(:pifi, :cache_limit, 250)

      one = album()
      first = track("track-1")
      second = track("track-2")
      third = track("track-3")

      # Two of the three fit, and the eviction can free nothing: the total is inside
      # the limit already.
      assert FavouriteAudio.read(%{one | favourite?: true}) == 2

      assert held(first.id)
      assert held(second.id)
      assert held(third.id) == nil
    end

    # A run that stepped over a large track and took a small one would leave room for
    # the next run to read that large track again.
    test "it stops at the first track that does not fit, and it tries no smaller one" do
      Application.put_env(:pifi, :cache_limit, 250)

      Req.Test.stub(Download, fn conn ->
        Plug.Conn.send_resp(conn, 200, String.duplicate("x", 100))
      end)

      one = album()
      large = track("track-1", byte_size: 500)
      small = track("track-2", byte_size: 10)

      assert FavouriteAudio.read(%{one | favourite?: true}) == 0

      assert held(large.id) == nil
      assert held(small.id) == nil
    end

    # The case that a limit alone cannot serve. The cache is inside its limit, so an
    # eviction with no target removes nothing, and the track is refused beside cold
    # artwork that the card would give up without complaint.
    test "the eviction makes room though the cache is inside its limit" do
      serve(100)
      cold = artwork("cold", 200)
      Application.put_env(:pifi, :cache_limit, 250)

      # Inside the limit, and still too small for a track of 100 bytes.
      assert Cache.free_bytes() == 50

      one = track("track-1")

      assert FavouriteAudio.read(one) == 1

      assert held(one.id)
      assert {:error, _reason} = Cache.fetch("artwork", cold.entry_key)
    end

    # The floor under the eviction. A released track is an ordinary entry, so without
    # the floor the coldest entry is the track that this same run read a moment ago.
    test "the eviction takes the cold entries and leaves what this run has written" do
      serve(100)
      cold = artwork("cold", 150)
      Application.put_env(:pifi, :cache_limit, 300)

      one = album()
      first = track("track-1")
      second = track("track-2")
      third = track("track-3")

      assert FavouriteAudio.read(%{one | favourite?: true}) == 3

      assert {:error, _reason} = Cache.fetch("artwork", cold.entry_key)
      assert held(first.id)
      assert held(second.id)
      assert held(third.id)
    end

    test "the guard estimates the size of a track that names none" do
      # 1000 kbit/s of 8 seconds is 1 MB, which is what a FLAC of that length holds.
      assert FavouriteAudio.size(%{byte_size: nil, duration_ms: 8000}) == 1_000_000
      assert FavouriteAudio.size(%{byte_size: 41_000_000, duration_ms: 8000}) == 41_000_000
      # A track that says neither counts as 50 MB.
      assert FavouriteAudio.size(%{byte_size: nil, duration_ms: nil}) == 50 * 1024 * 1024
    end
  end

  describe "the order of the marked items" do
    test "the newest mark comes first, so a full card holds what a person chose last" do
      Req.Test.stub(Download, fn _conn -> raise "the network must not be read" end)

      first = track("track-1")
      second = track("track-2")
      third = track("track-3")

      {:ok, _item} = Playback.set_favourite(first)
      {:ok, _item} = Playback.set_favourite(second)
      {:ok, _item} = Playback.set_favourite(third)

      marked = Playback.items_marked_for_audio!(Fill.source())

      assert Enum.map(marked, & &1.source_ref) == ["track-3", "track-2", "track-1"]
    end

    test "it names the marked item, and no item that a person left alone" do
      Req.Test.stub(Download, fn _conn -> raise "the network must not be read" end)

      one = album()
      track("track-1")
      {:ok, _item} = Playback.set_favourite(one)

      marked = Playback.items_marked_for_audio!(Fill.source())

      assert Enum.map(marked, & &1.source_ref) == ["album-1"]
    end

    test "it names no source but the one that a caller asks for" do
      Req.Test.stub(Download, fn _conn -> raise "the network must not be read" end)

      {:ok, _item} = Playback.set_favourite(track("track-1"))

      assert Playback.items_marked_for_audio!("podcasts") == []
    end

    # A show that a person follows holds episodes that read, so the run names it and the
    # count of the source holds it down.
    test "it names a show that a person follows" do
      serve(100)

      {:ok, marked} = Playback.set_favourite(show())

      assert [named] = Playback.items_marked_for_audio!("podcasts")
      assert named.id == marked.id
    end
  end
end
