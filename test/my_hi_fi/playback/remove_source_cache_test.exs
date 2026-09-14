defmodule MyHiFi.Playback.RemoveSourceCacheTest do
  use MyHiFi.DataCase, async: false
  use Oban.Testing, repo: MyHiFi.Repo

  alias MyHiFi.Artwork
  alias MyHiFi.Artwork.Thumbnail
  alias MyHiFi.Cache
  alias MyHiFi.Jellyfin.Fill
  alias MyHiFi.Playback
  alias MyHiFi.Playback.RemoveSourceCache
  alias MyHiFi.Player.Download
  alias MyHiFi.Test.Stations

  @png <<0x89, "PNG\r\n", 0x1A, "\n", "the rest of a small image">>

  setup do
    Application.put_env(:my_hi_fi, Artwork, plug: {Req.Test, Artwork}, retry: false)
    Req.Test.set_req_test_from_context(%{async: false})

    Req.Test.stub(Artwork, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, @png)
    end)

    File.rm_rf(Cache.directory())

    on_exit(fn ->
      Application.delete_env(:my_hi_fi, Artwork)
      File.rm_rf(Cache.directory())
    end)

    :ok
  end

  describe "the cache of one source" do
    test "the audio of a track goes, and the file of it with it" do
      track = track("track-1")
      entry = hold_audio(track.id)

      assert File.exists?(file(entry))
      assert Playback.remove_source_cache!(Fill.source()) == 1

      refute held(Download.namespace(), track.id)
      refute File.exists?(file(entry))
    end

    # The audio of a favourite waits for an eviction like any other entry, and a
    # download that grows carries `keep?`. Neither one may stay here: a person asked
    # for the room of the whole source back.
    test "an entry that no eviction may take goes as well" do
      track = track("track-1")
      hold_audio(track.id, keep?: true)

      assert Playback.remove_source_cache!(Fill.source()) == 1
      refute held(Download.namespace(), track.id)
    end

    test "the picture of an item goes, and the thumbnail of it with it" do
      album("album-1", "https://jellyfin.test/cover.png")
      {:ok, name} = Artwork.fetch("https://jellyfin.test/cover.png")
      put_thumbnail(held(Artwork.namespace(), name))

      assert Playback.remove_source_cache!(Fill.source()) == 1
      assert Artwork.name("https://jellyfin.test/cover.png") == nil
      refute held(Artwork.namespace(), name <> ".thumbnail")
    end

    # A publisher that uses one cover for an album and for each of its tracks names one
    # address, and the cache holds one file for it.
    test "two items of one address count as the one picture that they share" do
      album("album-1", "https://jellyfin.test/cover.png")
      track("track-1", artwork_url: "https://jellyfin.test/cover.png")
      {:ok, _name} = Artwork.fetch("https://jellyfin.test/cover.png")

      assert Playback.remove_source_cache!(Fill.source()) == 1
    end

    test "it takes nothing of another source" do
      station = Stations.create(%{title: "Newstalk ZB", favicon: "https://radio.test/logo.png"})
      {:ok, _name} = Artwork.fetch("https://radio.test/logo.png")
      entry = hold_audio(station.id)

      assert Playback.remove_source_cache!(Fill.source()) == 0
      assert Artwork.name("https://radio.test/logo.png") != nil
      assert File.exists?(file(entry))
    end

    test "a source that the cache holds nothing for removes nothing" do
      assert Playback.remove_source_cache!(Fill.source()) == 0
    end

    # The rows carry the marks, the places and the played state of a person, and a
    # source that comes back must show what it showed before.
    test "the rows of the source stay" do
      track = track("track-1")
      hold_audio(track.id)

      Playback.remove_source_cache!(Fill.source())

      assert Playback.get_item!(track.id)
    end
  end

  describe "the job" do
    test "a source that goes out of use asks for one job" do
      RemoveSourceCache.ask(MyHiFi.Source.Jellyfin)

      assert_enqueued(worker: RemoveSourceCache, args: %{source: "jellyfin"})
    end

    test "the job removes the cache of the source that it names" do
      track = track("track-1")
      hold_audio(track.id)

      assert :ok = perform_job(RemoveSourceCache, %{"source" => Fill.source()})
      refute held(Download.namespace(), track.id)
    end
  end

  defp album(ref, artwork_url) do
    Fill.albums([
      %{ref: ref, title: "Mezzanine", parent_ref: nil, artwork_url: artwork_url, subtitle: nil}
    ])

    item(ref)
  end

  defp track(ref, options \\ []) do
    Fill.tracks([
      %{
        ref: ref,
        title: "Track #{ref}",
        parent_ref: nil,
        artwork_url: Keyword.get(options, :artwork_url),
        subtitle: nil,
        duration_ms: 1000,
        byte_size: 100,
        number: 1,
        format: :flac
      }
    ])

    item(ref)
  end

  defp item(ref) do
    Enum.find(
      Playback.list_items!(),
      &(&1.source == Fill.source() and &1.source_ref == ref)
    )
  end

  defp hold_audio(id, options \\ []) do
    Cache.put!(Download.namespace(), id, %{
      bytes: "the audio of a track",
      content_type: "audio/flac",
      keep?: Keyword.get(options, :keep?, false)
    })
  end

  defp held(namespace, key) do
    case Cache.fetch(namespace, key) do
      {:ok, entry} -> entry
      {:error, _reason} -> nil
    end
  end

  defp file(entry), do: Path.join(Cache.directory(), entry.key)

  # `vipsthumbnail` comes from `nbpr_libvips`, and that dependency belongs to the
  # target alone. A test on the host therefore writes what a device writes.
  defp put_thumbnail(entry) do
    Cache.put!(Artwork.namespace(), entry.entry_key <> ".thumbnail", %{
      bytes: @png,
      content_type: "image/jpeg",
      variant_of_blob_id: entry.id,
      variant_name: "thumbnail",
      variant_digest: Thumbnail.digest()
    })
  end
end
