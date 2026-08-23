defmodule MyHiFi.Podcast.Feed.ParserTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Podcast.Feed.Parser

  doctest Parser, import: true

  # A feed arrives in chunks, so each test reads one. `size` proves that the
  # answer does not depend on where a chunk ends: an element, an attribute, and a
  # tag name each cross a boundary at one of these sizes.
  defp read(xml, options \\ [], size \\ 8) do
    {:ok, parser} = Parser.new(options)

    xml
    |> chunks(size)
    |> Enum.reduce_while({:cont, parser}, fn chunk, {:cont, parser} ->
      # Each tag is named, so a wrong one raises here instead of passing through.
      case Parser.feed(parser, chunk) do
        {:cont, parser} -> {:cont, {:cont, parser}}
        {:done, feed} -> {:halt, {:done, feed}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:cont, parser} -> Parser.finish(parser)
      {:done, feed} -> {:ok, feed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp chunks(binary, size) do
    Stream.unfold(binary, fn
      <<>> ->
        nil

      rest ->
        take = min(size, byte_size(rest))
        {binary_part(rest, 0, take), binary_part(rest, take, byte_size(rest) - take)}
    end)
  end

  defp feed(channel, items) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
      <channel>
    #{channel}
    #{items}
      </channel>
    </rss>
    """
  end

  defp item(inner), do: "    <item>\n#{inner}\n    </item>"

  defp enclosure(url, options \\ []) do
    type = Keyword.get(options, :type, "audio/mpeg")
    length = Keyword.get(options, :length, "12345")

    ~s(      <enclosure url="#{url}" length="#{length}" type="#{type}" />)
  end

  describe "the channel" do
    test "it reads the title, the description, the author and the artwork" do
      xml =
        feed(
          """
              <title>Road Work</title>
              <description>A show about work.</description>
              <itunes:author>Dan Benjamin</itunes:author>
              <itunes:image href="https://example.test/cover.jpg" />
          """,
          ""
        )

      assert {:ok, %{show: show, episodes: []}} = read(xml)

      assert show == %{
               title: "Road Work",
               description: "A show about work.",
               author: "Dan Benjamin",
               artwork_url: "https://example.test/cover.jpg"
             }
    end

    test "`itunes:image` wins over `image`, and the order in the feed does not matter" do
      before = """
          <itunes:image href="https://example.test/itunes.jpg" />
          <image><url>https://example.test/rss.jpg</url><title>Ignore me</title></image>
          <title>Road Work</title>
      """

      later = """
          <image><url>https://example.test/rss.jpg</url><title>Ignore me</title></image>
          <itunes:image href="https://example.test/itunes.jpg" />
          <title>Road Work</title>
      """

      for channel <- [before, later] do
        assert {:ok, %{show: show}} = read(feed(channel, ""))
        assert show.artwork_url == "https://example.test/itunes.jpg"
        # `<image><title>` is not the title of the show.
        assert show.title == "Road Work"
      end
    end

    test "it uses `image` when the feed holds no `itunes:image`" do
      channel = "    <image><url>https://example.test/rss.jpg</url></image>"

      assert {:ok, %{show: show}} = read(feed(channel, ""))
      assert show.artwork_url == "https://example.test/rss.jpg"
    end

    test "an absent element gives nil, and it does not give an empty string" do
      assert {:ok, %{show: show}} = read(feed("    <title>  </title>", ""))

      assert show == %{title: nil, description: nil, author: nil, artwork_url: nil}
    end
  end

  describe "an item" do
    test "it reads every element that the firmware uses" do
      xml =
        feed(
          "    <title>Road Work</title>",
          item("""
                <title>257: Emotional Facts</title>
                <guid>d163aee7</guid>
                <pubDate>Thu, 02 Jun 2022 14:00:00 -0500</pubDate>
                <description>A description.</description>
                <itunes:subtitle>A subtitle.</itunes:subtitle>
                <itunes:duration>48:41</itunes:duration>
                <itunes:image href="https://example.test/episode.jpg" />
          #{enclosure("https://example.test/257.mp3", length: "46739203")}
          """)
        )

      assert {:ok, %{episodes: [episode]}} = read(xml)

      assert episode == %{
               guid: "d163aee7",
               title: "257: Emotional Facts",
               subtitle: "A subtitle.",
               description: "A description.",
               audio_url: "https://example.test/257.mp3",
               mime_type: "audio/mpeg",
               byte_length: 46_739_203,
               duration_ms: 2_921_000,
               published_at: ~U[2022-06-02 19:00:00Z],
               artwork_url: "https://example.test/episode.jpg"
             }
    end

    test "the address of the audio identifies an episode that holds no guid" do
      xml = feed("", item(enclosure("https://example.test/1.mp3")))

      assert {:ok, %{episodes: [episode]}} = read(xml)
      assert episode.guid == "https://example.test/1.mp3"
    end

    test "an item with no enclosure gives no episode" do
      xml =
        feed("", [
          item("      <title>Text only</title>"),
          item("      <title>Playable</title>\n" <> enclosure("https://example.test/1.mp3"))
        ])

      assert {:ok, %{episodes: [episode]}} = read(xml)
      assert episode.title == "Playable"
    end

    test "an item with an empty enclosure address gives no episode" do
      xml = feed("", item(enclosure("")))

      assert {:ok, %{episodes: []}} = read(xml)
    end

    test "the title of an item is not the title of the channel" do
      xml =
        feed(
          "    <title>The show</title>",
          item("      <title>The episode</title>\n" <> enclosure("https://example.test/1.mp3"))
        )

      assert {:ok, %{show: show, episodes: [episode]}} = read(xml)
      assert show.title == "The show"
      assert episode.title == "The episode"
    end

    test "an element inside a captured element keeps its text with the outer one" do
      xml =
        feed(
          "",
          item("""
                <description>Read <a href="https://example.test">this</a> now.</description>
          #{enclosure("https://example.test/1.mp3")}
          """)
        )

      assert {:ok, %{episodes: [episode]}} = read(xml)
      assert episode.description == "Read this now."
    end

    test "it reads text that arrives as CDATA" do
      xml =
        feed(
          "",
          item("""
                <title><![CDATA[Bees & Trees]]></title>
          #{enclosure("https://example.test/1.mp3")}
          """)
        )

      assert {:ok, %{episodes: [episode]}} = read(xml)
      assert episode.title == "Bees & Trees"
    end

    test "it reads an escaped entity" do
      xml =
        feed(
          "",
          item(
            "      <title>Bees &amp; Trees</title>\n" <> enclosure("https://example.test/1.mp3")
          )
        )

      assert {:ok, %{episodes: [episode]}} = read(xml)
      assert episode.title == "Bees & Trees"
    end

    test "a length or a duration that no reader knows gives nil" do
      xml =
        feed(
          "",
          item("""
                <itunes:duration>about an hour</itunes:duration>
          #{enclosure("https://example.test/1.mp3", length: "unknown")}
          """)
        )

      assert {:ok, %{episodes: [episode]}} = read(xml)
      assert episode.duration_ms == nil
      assert episode.byte_length == nil
    end

    test "it keeps the order of the feed, and the newest episode comes first" do
      items = Enum.map(1..3, &item(enclosure("https://example.test/#{&1}.mp3")))

      assert {:ok, %{episodes: episodes}} = read(feed("", items))

      assert Enum.map(episodes, & &1.audio_url) == [
               "https://example.test/1.mp3",
               "https://example.test/2.mp3",
               "https://example.test/3.mp3"
             ]
    end
  end

  describe "the limit on the episodes" do
    test "it stops at `:max_items` and it gives the answer before the feed ends" do
      items = Enum.map(1..50, &item(enclosure("https://example.test/#{&1}.mp3")))

      assert {:ok, %{episodes: episodes}} = read(feed("", items), max_items: 3)

      assert Enum.map(episodes, & &1.audio_url) == [
               "https://example.test/1.mp3",
               "https://example.test/2.mp3",
               "https://example.test/3.mp3"
             ]
    end

    test "it reads the channel before it stops" do
      items = Enum.map(1..10, &item(enclosure("https://example.test/#{&1}.mp3")))

      assert {:ok, %{show: show}} =
               read(feed("    <title>Road Work</title>", items), max_items: 1)

      assert show.title == "Road Work"
    end

    test "an item with no enclosure does not count against the limit" do
      items = [
        item("      <title>Text only</title>"),
        item(enclosure("https://example.test/1.mp3"))
      ]

      assert {:ok, %{episodes: [episode]}} = read(feed("", items), max_items: 1)
      assert episode.audio_url == "https://example.test/1.mp3"
    end
  end

  describe "a document that this firmware does not read" do
    test "an Atom document gives an error" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <feed xmlns="http://www.w3.org/2005/Atom"><title>Not RSS</title></feed>
      """

      assert {:error, :not_rss} = read(xml)
    end

    test "an HTML error page gives an error" do
      assert {:error, :not_rss} = read("<html><body>Not found</body></html>")
    end

    test "a document that stops in the middle gives an error" do
      xml = feed("    <title>Road Work</title>", "") |> binary_part(0, 120)

      assert {:error, %Saxy.ParseError{}} = read(xml)
    end
  end

  describe "the chunk boundaries" do
    test "the answer does not depend on where a chunk ends" do
      xml =
        feed(
          "    <title>Road Work</title>\n    <itunes:image href=\"https://example.test/c.jpg\" />",
          item("""
                <title>257: Emotional Facts</title>
                <pubDate>Thu, 02 Jun 2022 14:00:00 -0500</pubDate>
                <itunes:duration>48:41</itunes:duration>
          #{enclosure("https://example.test/257.mp3")}
          """)
        )

      answers =
        for size <- [1, 2, 3, 7, 13, 64, 1024, byte_size(xml)] do
          assert {:ok, feed} = read(xml, [], size)
          feed
        end

      assert [one] = Enum.uniq(answers)
      assert one.show.title == "Road Work"
      assert [%{duration_ms: 2_921_000, published_at: ~U[2022-06-02 19:00:00Z]}] = one.episodes
    end
  end

  describe "published_at/1" do
    test "it reads the forms that a feed writes" do
      assert Parser.published_at("Thu, 02 Jun 2022 14:00:00 -0500") ==
               ~U[2022-06-02 19:00:00Z]

      assert Parser.published_at("Sat, 22 Aug 2026 10:00:00 +0000") ==
               ~U[2026-08-22 10:00:00Z]

      assert Parser.published_at("Mon, 3 Mar 2025 09:05:00 GMT") ==
               ~U[2025-03-03 09:05:00Z]

      # No day name, and no seconds.
      assert Parser.published_at("3 Mar 2025 09:05 +1200") == ~U[2025-03-02 21:05:00Z]
    end

    test "it keeps the offset, and it does not remove it" do
      utc = Parser.published_at("Thu, 02 Jun 2022 14:00:00 +0000")
      chicago = Parser.published_at("Thu, 02 Jun 2022 14:00:00 -0500")

      assert DateTime.diff(chicago, utc) == 5 * 3600
    end

    test "it reads the obsolete zone names of RFC 2822" do
      assert Parser.published_at("Tue, 01 Apr 2025 06:00:00 PDT") ==
               ~U[2025-04-01 13:00:00Z]

      assert Parser.published_at("Tue, 01 Apr 2025 06:00:00 EST") ==
               ~U[2025-04-01 11:00:00Z]
    end

    test "an unknown zone name reads as no offset" do
      assert Parser.published_at("Tue, 01 Apr 2025 06:00:00 XYZ") ==
               ~U[2025-04-01 06:00:00Z]
    end

    test "a date with no zone reads as no offset" do
      assert Parser.published_at("Tue, 01 Apr 2025 06:00:00") == ~U[2025-04-01 06:00:00Z]
    end

    test "a year of two digits reads as RFC 2822 asks" do
      assert Parser.published_at("1 Jan 99 00:00:00 +0000") == ~U[1999-01-01 00:00:00Z]
      assert Parser.published_at("1 Jan 05 00:00:00 +0000") == ~U[2005-01-01 00:00:00Z]
    end

    test "text that holds no date gives nil" do
      for text <- ["", "some time last week", "2026-08-01", "32 Foo 2025 06:00:00 +0000"] do
        assert Parser.published_at(text) == nil, "read #{inspect(text)}"
      end
    end

    test "a day that the month does not hold gives nil" do
      assert Parser.published_at("31 Feb 2025 06:00:00 +0000") == nil
    end

    test "a time that no clock holds gives nil" do
      assert Parser.published_at("1 Jan 2025 25:00:00 +0000") == nil
    end
  end

  describe "duration_ms/1" do
    test "it reads whole seconds" do
      assert Parser.duration_ms("2921") == 2_921_000
    end

    test "it reads minutes and seconds" do
      assert Parser.duration_ms("48:41") == 2_921_000
    end

    test "it reads hours, minutes and seconds" do
      assert Parser.duration_ms("01:02:13") == 3_733_000
      assert Parser.duration_ms("1:02:13") == 3_733_000
    end

    test "it removes the space around the value" do
      assert Parser.duration_ms("  48:41  ") == 2_921_000
    end

    test "a length that no reader knows gives nil" do
      for text <- ["", "about an hour", "1:2:3:4", "48:", "aa:bb"] do
        assert Parser.duration_ms(text) == nil, "read #{inspect(text)}"
      end
    end

    test "a length of nothing gives nil, because an episode has a length" do
      assert Parser.duration_ms("0") == nil
      assert Parser.duration_ms("00:00") == nil
    end
  end
end
