defmodule PiFi.Podcast.IndexTest do
  use PiFi.DataCase, async: false

  alias PiFi.Podcast.Index
  alias PiFi.Settings

  doctest Index, import: true

  setup do
    Application.put_env(:pifi, Index, plug: {Req.Test, Index}, retry: false)
    on_exit(fn -> Application.delete_env(:pifi, Index) end)
    :ok
  end

  defp put_key do
    {:ok, _setting} = Settings.put(Index.key_setting(), "THEKEY")
    {:ok, _setting} = Settings.put(Index.secret_setting(), "THESECRET")
    :ok
  end

  # Each stub sends the request back to the test, so a test can read the headers
  # and the query that the client built.
  defp stub(body, options \\ []) do
    status = Keyword.get(options, :status, 200)
    test = self()

    Req.Test.stub(Index, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test, {:request, conn.request_path, conn.params, Map.new(conn.req_headers)})

      Req.Test.json(Plug.Conn.put_status(conn, status), body)
    end)
  end

  defp feed(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => 920_666,
        "url" => "https://example.test/rss",
        "title" => "The Rest Is History",
        "author" => "Goalhanger",
        "ownerName" => "Goalhanger Podcasts",
        "description" => "History.",
        "image" => "https://example.test/small.jpg",
        "artwork" => "https://example.test/large.jpg"
      },
      overrides
    )
  end

  describe "the headers of a request" do
    test "it sends the four headers that the index asks for" do
      put_key()
      stub(%{"status" => "true", "feeds" => [], "count" => 0})

      assert {:ok, []} = Index.search("history")

      assert_receive {:request, "/api/1.0/search/byterm", _params, headers}

      assert headers["x-auth-key"] == "THEKEY"
      assert headers["user-agent"] == "PiFi/0.1"
      assert {date, ""} = Integer.parse(headers["x-auth-date"])
      assert headers["authorization"] == Index.signature("THEKEY", "THESECRET", "#{date}")
    end

    test "the date comes from the clock, and it is inside the window of the index" do
      put_key()
      stub(%{"feeds" => []})

      assert {:ok, []} = Index.search("history")

      assert_receive {:request, _path, _params, headers}
      {date, ""} = Integer.parse(headers["x-auth-date"])

      # The index holds a window of 3 minutes.
      assert abs(System.os_time(:second) - date) < 10
    end
  end

  describe "search/2" do
    test "it gives the shows in the shape that the resource accepts" do
      put_key()
      stub(%{"feeds" => [feed()], "count" => 1})

      assert {:ok, [show]} = Index.search("history")

      assert show == %{
               feed_url: "https://example.test/rss",
               index_id: 920_666,
               title: "The Rest Is History",
               author: "Goalhanger",
               description: "History.",
               artwork_url: "https://example.test/large.jpg",
               # `PiFi.Podcast.Fill` writes each one as a facet, so the Categories
               # branch needs no read of its own.
               categories: []
             }
    end

    test "a show of the index writes a row with no change" do
      put_key()
      stub(%{"feeds" => [feed()]})

      assert {:ok, [attrs]} = Index.search("history")
      # A show holds the address of the feed and the identifier of the index. The
      # title and the picture go to `PiFi.Playback.Item`.
      assert {:ok, show} =
               PiFi.Podcast.upsert_show_from_index(Map.take(attrs, [:feed_url, :index_id]))

      assert show.feed_url == "https://example.test/rss"
      assert show.index_id == 920_666
      # The index gives the title, and the fill writes it to the item.
      assert attrs.title == "The Rest Is History"
    end

    test "it sends the term and the limit" do
      put_key()
      stub(%{"feeds" => []})

      assert {:ok, []} = Index.search("the rest is history", limit: 5)

      assert_receive {:request, _path, params, _headers}
      assert params["q"] == "the rest is history"
      assert params["max"] == "5"
    end

    test "it steps over a feed that cannot become a row" do
      put_key()

      stub(%{
        "feeds" => [
          feed(),
          feed(%{"url" => nil}),
          feed(%{"title" => "   "}),
          %{"nonsense" => true}
        ]
      })

      assert {:ok, [show]} = Index.search("history")
      assert show.title == "The Rest Is History"
    end

    test "an answer with no feeds gives an empty list" do
      put_key()
      stub(%{"status" => "true", "count" => 0})

      assert {:ok, []} = Index.search("nothing at all")
    end
  end

  describe "show_by_feed_url/1" do
    test "it gives one show" do
      put_key()
      stub(%{"status" => "true", "feed" => feed()})

      assert {:ok, show} = Index.show_by_feed_url("https://example.test/rss")
      assert show.title == "The Rest Is History"

      assert_receive {:request, "/api/1.0/podcasts/byfeedurl", params, _headers}
      assert params["url"] == "https://example.test/rss"
    end

    test "a 400 means that the index does not hold the feed" do
      put_key()
      stub(%{"status" => "false", "description" => "no feed"}, status: 400)

      # A read against the real service on 2026-08-23 gave 400 for a feed that the
      # index does not hold. A private feed is always one of those, so this must
      # not read as a fault.
      assert {:error, :not_in_index} = Index.show_by_feed_url("https://example.test/private/rss")
    end

    test "an empty feed in a 200 also means that the index does not hold it" do
      put_key()
      stub(%{"status" => "true", "feed" => []})

      assert {:error, :not_in_index} = Index.show_by_feed_url("https://example.test/private/rss")
    end

    test "a 400 from another endpoint stays a status error" do
      put_key()
      stub(%{"status" => "false"}, status: 400)

      assert {:error, {:unexpected_status, 400}} = Index.search("history")
    end
  end

  describe "trending/1" do
    test "it asks for English, and it names no category" do
      put_key()
      stub(%{"feeds" => [feed()]})

      assert {:ok, [_show]} = Index.trending()

      assert_receive {:request, "/api/1.0/podcasts/trending", params, _headers}
      assert params["lang"] == "en"
      refute Map.has_key?(params, "cat")
    end

    test "it names one category when a caller gives one" do
      put_key()
      stub(%{"feeds" => []})

      assert {:ok, []} = Index.trending(category: "History", limit: 10)

      assert_receive {:request, _path, params, _headers}
      assert params["cat"] == "History"
      assert params["max"] == "10"
    end
  end

  describe "categories/0" do
    test "it gives the categories, sorted by the name" do
      put_key()

      stub(%{
        "feeds" => [
          %{"id" => 55, "name" => "News"},
          %{"id" => 9, "name" => "Arts"},
          %{"id" => 77, "name" => ""}
        ]
      })

      assert {:ok, categories} = Index.categories()

      assert categories == [%{id: 9, name: "Arts"}, %{id: 55, name: "News"}]
    end
  end

  describe "a device with no key" do
    test "each call gives `:no_api_key`, and it reaches no network" do
      stub(%{"feeds" => [feed()]})

      assert {:error, :no_api_key} = Index.search("history")
      assert {:error, :no_api_key} = Index.trending()
      assert {:error, :no_api_key} = Index.categories()
      assert {:error, :no_api_key} = Index.show_by_feed_url("https://example.test/rss")

      refute_receive {:request, _path, _params, _headers}
    end

    test "a key with no secret is no key" do
      {:ok, _setting} = Settings.put(Index.key_setting(), "THEKEY")

      assert {:error, :no_api_key} = Index.search("history")
    end

    test "the settings refuse a blank key, so no blank key can be stored" do
      # `PiFi.Settings.Setting` removes the space around a value, and it then
      # refuses one that holds nothing. This is why `credentials/0` needs no check
      # of its own.
      assert {:error, _reason} = Settings.put(Index.key_setting(), "   ")
      assert {:error, _reason} = Settings.put(Index.key_setting(), "")

      assert {:error, :no_api_key} = Index.search("history")
    end

    test "`configured?` says whether a key is present" do
      refute Index.configured?()

      put_key()

      assert Index.configured?()
    end
  end

  describe "an answer that the client refuses" do
    test "a 401 says that the index refused the key" do
      put_key()
      stub(%{"status" => "false"}, status: 401)

      assert {:error, :key_refused} = Index.search("history")
    end

    test "another status gives that status" do
      put_key()
      stub(%{"status" => "false"}, status: 500)

      assert {:error, {:unexpected_status, 500}} = Index.search("history")
    end

    test "a network fault gives the reason of `Req`" do
      put_key()
      Req.Test.stub(Index, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} = Index.search("history")
    end
  end

  describe "show/1" do
    test "the owner names a show that holds no author" do
      assert %{author: "Goalhanger Podcasts"} = Index.show(feed(%{"author" => nil}))
      assert %{author: "Goalhanger Podcasts"} = Index.show(feed(%{"author" => "  "}))
    end

    test "the artwork of the index comes before the image of the feed" do
      assert %{artwork_url: "https://example.test/large.jpg"} = Index.show(feed())

      assert %{artwork_url: "https://example.test/small.jpg"} =
               Index.show(feed(%{"artwork" => nil}))

      assert %{artwork_url: nil} = Index.show(feed(%{"artwork" => nil, "image" => nil}))
    end

    test "a feed with no address or no title becomes nothing" do
      assert Index.show(feed(%{"url" => nil})) == nil
      assert Index.show(feed(%{"url" => ""})) == nil
      assert Index.show(feed(%{"title" => nil})) == nil
      assert Index.show(nil) == nil
      assert Index.show(%{}) == nil
    end

    test "it removes the space around a title and an address" do
      assert %{title: "The Rest Is History", feed_url: "https://example.test/rss"} =
               Index.show(feed(%{"title" => "  The Rest Is History  "}))
    end
  end
end
