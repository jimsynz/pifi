defmodule PiFi.Player.HlsTest do
  use ExUnit.Case, async: true

  alias PiFi.Player.Hls

  setup do
    Application.put_env(:pifi, Hls, plug: {Req.Test, Hls}, retry: false)
    on_exit(fn -> Application.delete_env(:pifi, Hls) end)
    :ok
  end

  # Each answer comes from the address that the test asks for, so one stub serves
  # a master playlist and the media playlist that it names.
  defp stub(answers) do
    Req.Test.stub(Hls, fn conn ->
      case Map.fetch(answers, conn.request_path) do
        {:ok, body} -> Req.Test.text(conn, body)
        :error -> Plug.Conn.send_resp(conn, 404, "no such playlist")
      end
    end)
  end

  defp master(codecs, variant) do
    """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-STREAM-INF:BANDWIDTH=150973,CODECS="#{codecs}"
    #{variant}
    """
  end

  defp media(segment) do
    """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:11
    #EXT-X-MEDIA-SEQUENCE:255532
    #EXTINF:10.031,
    #{segment}
    """
  end

  describe "a master playlist" do
    test "reads MPEG-TS with AAC" do
      stub(%{
        "/playlist.m3u8" => master("mp4a.40.2", "chunklist.m3u8"),
        "/chunklist.m3u8" => media("media_255532.ts")
      })

      assert {:ok, result} = Hls.resolve("http://radio.test/playlist.m3u8", :aac)
      assert result.container == :mpeg_ts
      assert result.format == :aac
      assert URI.to_string(result.media_playlist_uri) == "http://radio.test/chunklist.m3u8"
    end

    test "reads MP3 inside MPEG-TS from the codec of the variant" do
      # `mp4a.40.34` is MPEG-1 Layer 3, and 8 New Zealand stations send it.
      stub(%{
        "/playlist.m3u8" => master("mp4a.40.34", "chunklist.m3u8"),
        "/chunklist.m3u8" => media("media_1.ts")
      })

      assert {:ok, %{container: :mpeg_ts, format: :mp3}} =
               Hls.resolve("http://radio.test/playlist.m3u8", :aac)
    end

    test "reads AAC with no container when the segments are not MPEG-TS" do
      stub(%{
        "/playlist.m3u8" => master("mp4a.40.5", "chunklist.m3u8"),
        "/chunklist.m3u8" => media("segment_1.aac")
      })

      assert {:ok, %{container: :none, format: :aac}} =
               Hls.resolve("http://radio.test/playlist.m3u8", :mp3)
    end

    test "the codec of the playlist wins over the codec of the station" do
      stub(%{
        "/playlist.m3u8" => master("mp4a.40.34", "chunklist.m3u8"),
        "/chunklist.m3u8" => media("media_1.ts")
      })

      assert {:ok, %{format: :mp3}} = Hls.resolve("http://radio.test/playlist.m3u8", :aac)
    end

    test "takes the variant of the lowest bandwidth" do
      stub(%{
        "/playlist.m3u8" => """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=256000,CODECS="mp4a.40.2"
        high.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS="mp4a.40.2"
        low.m3u8
        """,
        "/low.m3u8" => media("media_1.ts")
      })

      assert {:ok, result} = Hls.resolve("http://radio.test/playlist.m3u8", :aac)
      assert URI.to_string(result.media_playlist_uri) == "http://radio.test/low.m3u8"
    end

    test "gives an error when the media playlist is absent" do
      stub(%{"/playlist.m3u8" => master("mp4a.40.2", "gone.m3u8")})

      assert {:error, {:playlist_status, 404}} =
               Hls.resolve("http://radio.test/playlist.m3u8", :aac)
    end
  end

  describe "a media playlist" do
    test "reads it where it is, and takes the codec of the station" do
      # 4 of the 44 New Zealand stations give a media playlist and no master.
      stub(%{"/chunklist.m3u8" => media("media_1.ts")})

      assert {:ok, result} = Hls.resolve("http://radio.test/chunklist.m3u8", :mp3)
      assert result.container == :mpeg_ts
      assert result.format == :mp3
      assert URI.to_string(result.media_playlist_uri) == "http://radio.test/chunklist.m3u8"
    end

    test "reads a segment with no container" do
      stub(%{"/chunklist.m3u8" => media("segment_1.aac")})

      assert {:ok, %{container: :none, format: :aac}} =
               Hls.resolve("http://radio.test/chunklist.m3u8", :aac)
    end

    test "a segment address that holds a query still names its container" do
      stub(%{"/chunklist.m3u8" => media("media_1.ts?token=abc123")})

      assert {:ok, %{container: :mpeg_ts}} =
               Hls.resolve("http://radio.test/chunklist.m3u8", :aac)
    end
  end

  describe "an answer that this module cannot use" do
    test "gives an error for a playlist that is absent" do
      stub(%{})

      assert {:error, {:playlist_status, 404}} = Hls.resolve("http://radio.test/gone.m3u8", :aac)
    end

    test "reads a playlist with no segment as MPEG-TS" do
      stub(%{"/empty.m3u8" => "#EXTM3U\n#EXT-X-TARGETDURATION:10\n"})

      assert {:ok, %{container: :mpeg_ts}} = Hls.resolve("http://radio.test/empty.m3u8", :aac)
    end

    test "gives an error for a master playlist that names no variant" do
      stub(%{"/master.m3u8" => "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n"})

      assert {:error, _reason} = Hls.resolve("http://radio.test/master.m3u8", :aac)
    end
  end
end
