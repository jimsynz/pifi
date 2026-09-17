defmodule PiFi.Podcast.FeedTest do
  use ExUnit.Case, async: true

  alias PiFi.Podcast.Feed

  setup do
    Application.put_env(:pifi, Feed, plug: {Req.Test, Feed})
    on_exit(fn -> Application.delete_env(:pifi, Feed) end)
    :ok
  end

  defp stub(fun), do: Req.Test.stub(Feed, fun)

  defp serve(body, options \\ []) do
    status = Keyword.get(options, :status, 200)
    headers = Keyword.get(options, :headers, [])

    stub(fn conn ->
      conn
      |> then(
        &Enum.reduce(headers, &1, fn {k, v}, acc -> Plug.Conn.put_resp_header(acc, k, v) end)
      )
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  defp feed(items) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
      <channel>
        <title>Road Work</title>
        <itunes:author>Dan Benjamin</itunes:author>
        <itunes:image href="https://example.test/cover.jpg" />
    #{items}
      </channel>
    </rss>
    """
  end

  defp item(number) do
    """
        <item>
          <title>Episode #{number}</title>
          <guid>episode-#{number}</guid>
          <pubDate>Thu, 02 Jun 2022 14:00:00 -0500</pubDate>
          <itunes:duration>48:41</itunes:duration>
          <enclosure url="https://example.test/#{number}.mp3" length="123" type="audio/mpeg" />
        </item>
    """
  end

  describe "read/2" do
    test "it gives the show and the episodes" do
      serve(feed(item(1) <> item(2)))

      assert {:ok, %{show: show, episodes: episodes}} = Feed.read("https://example.test/rss")

      assert show.title == "Road Work"
      assert show.author == "Dan Benjamin"
      assert show.artwork_url == "https://example.test/cover.jpg"

      assert Enum.map(episodes, & &1.guid) == ["episode-1", "episode-2"]
      assert [%{duration_ms: 2_921_000, published_at: ~U[2022-06-02 19:00:00Z]} | _] = episodes
    end

    test "it reads a feed that arrives in many chunks" do
      items = Enum.map_join(1..40, &item/1)
      body = feed(items)

      stub(fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)

        body
        |> String.to_charlist()
        |> Enum.chunk_every(64)
        |> Enum.reduce(conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, List.to_string(chunk))
          conn
        end)
      end)

      assert {:ok, %{episodes: episodes}} = Feed.read("https://example.test/rss")
      assert length(episodes) == 40
    end

    test "it passes `:max_items` to the parser" do
      serve(feed(Enum.map_join(1..20, &item/1)))

      assert {:ok, %{episodes: episodes}} = Feed.read("https://example.test/rss", max_items: 5)
      assert Enum.map(episodes, & &1.guid) == Enum.map(1..5, &"episode-#{&1}")
    end

    test "it reads the show even when it stops at the limit" do
      serve(feed(Enum.map_join(1..20, &item/1)))

      assert {:ok, %{show: show}} = Feed.read("https://example.test/rss", max_items: 1)
      assert show.title == "Road Work"
    end
  end

  describe "an answer that holds no feed" do
    test "a status that is not 200 gives that status" do
      serve("<html><body>Not found</body></html>", status: 404)

      assert {:error, {:unexpected_status, 404}} = Feed.read("https://example.test/rss")
    end

    test "a status that is not 200 and no body still gives that status" do
      serve("", status: 500)

      assert {:error, {:unexpected_status, 500}} = Feed.read("https://example.test/rss")
    end

    test "an Atom document gives an error" do
      serve(~s(<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"></feed>))

      assert {:error, :not_rss} = Feed.read("https://example.test/rss")
    end

    test "an answer with no body gives an error" do
      serve("")

      assert {:error, :not_rss} = Feed.read("https://example.test/rss")
    end

    test "a document that stops in the middle gives an error" do
      serve(binary_part(feed(item(1)), 0, 150))

      assert {:error, %Saxy.ParseError{}} = Feed.read("https://example.test/rss")
    end

    test "a compressed answer names the encoding, and it gives no parse error" do
      serve(:zlib.gzip(feed(item(1))), headers: [{"content-encoding", "gzip"}])

      assert {:error, {:unsupported_encoding, "gzip"}} = Feed.read("https://example.test/rss")
    end

    test "an answer that names the identity encoding reads as it is" do
      serve(feed(item(1)), headers: [{"content-encoding", "identity"}])

      assert {:ok, %{episodes: [_episode]}} = Feed.read("https://example.test/rss")
    end

    test "a network fault gives the reason of `Req`" do
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Feed.read("https://example.test/rss")
    end
  end

  describe "the limit on the size" do
    test "a feed above the limit gives an error and it reads no more" do
      # The limit is 32 MB. A channel with no end, and 40 MB of padding inside a
      # comment, reaches it without a real feed of that size.
      padding = String.duplicate("x", 1024 * 1024)

      stub(fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)

        {:ok, conn} =
          Plug.Conn.chunk(conn, ~s(<?xml version="1.0"?><rss version="2.0"><channel><!-- ))

        Enum.reduce_while(1..40, conn, fn _number, conn ->
          case Plug.Conn.chunk(conn, padding) do
            {:ok, conn} -> {:cont, conn}
            # The reader stops the download, so the writer stops as well.
            {:error, :closed} -> {:halt, conn}
          end
        end)
      end)

      assert {:error, :feed_too_large} = Feed.read("https://example.test/rss")
    end
  end
end
