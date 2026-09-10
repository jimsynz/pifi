defmodule MyHiFi.Radio.FillTest do
  use MyHiFi.DataCase, async: false
  use Oban.Testing, repo: MyHiFi.Repo

  require Ash.Query

  alias MyHiFi.Playback
  alias MyHiFi.Playback.Facet
  alias MyHiFi.Playback.Item
  alias MyHiFi.Playback.ItemFacet
  alias MyHiFi.Radio.Fill

  defp station(overrides \\ %{}) do
    Map.merge(
      %{
        remote_id: "remote-#{System.unique_integer([:positive])}",
        title: "RNZ National",
        stream_url: "http://example.test/stream.mp3",
        codec: "MP3",
        bitrate: 128,
        hls?: false,
        country_code: "NZ",
        language: "english",
        tags: ["news", "talk"],
        artwork_url: "https://example.test/logo.png",
        click_count: 42
      },
      overrides
    )
  end

  defp values_of(key) do
    key |> Playback.facets_of_key!() |> Enum.map(& &1.value.value) |> Enum.sort()
  end

  # **A station of a list draws its logo, and nothing else asks for one.** A page
  # builds the address of a picture and reads nothing, so the read of the list is what
  # asks. See `MyHiFi.Artwork.ensure/1`.
  describe "the logos" do
    test "it asks for the logo of each station that it wrote" do
      Fill.stations([
        station(%{remote_id: "one", artwork_url: "https://example.test/one.png"}),
        station(%{remote_id: "two", artwork_url: "https://example.test/two.png"})
      ])

      assert_enqueued(
        worker: MyHiFi.Artwork.Worker,
        args: %{"url" => "https://example.test/one.png"}
      )

      assert_enqueued(
        worker: MyHiFi.Artwork.Worker,
        args: %{"url" => "https://example.test/two.png"}
      )
    end

    test "a station that names no logo asks for nothing" do
      Fill.stations([station(%{remote_id: "one", artwork_url: nil})])

      refute_enqueued(worker: MyHiFi.Artwork.Worker)
    end
  end

  describe "writing a station" do
    test "it writes one item with the fields that the player needs" do
      assert 1 = Fill.stations([station(%{remote_id: "one", title: "RNZ National"})])

      assert [item] = Playback.items_of_source!("internet-radio")
      assert item.source_ref == "one"
      assert item.title == "RNZ National"
      assert item.kind == :track
      assert item.url == "http://example.test/stream.mp3"
      assert item.transport == :http
      assert item.format == :mp3
      assert item.live? == true
      assert item.artwork_url == "https://example.test/logo.png"
    end

    # The codec and the bitrate tell a person what to expect of the sound. It is a
    # column, so a page draws a list without a join for each row.
    test "the codec and the bitrate become the subtitle" do
      Fill.stations([station(%{codec: "MP3", bitrate: 128})])

      assert [%{subtitle: "MP3, 128 kbps"}] = Playback.items_of_source!("internet-radio")
    end

    test "a station with no bitrate names its codec alone" do
      Fill.stations([station(%{codec: "AAC", bitrate: 0})])

      assert [%{subtitle: "AAC"}] = Playback.items_of_source!("internet-radio")
    end

    # The station list is in the order that a person elsewhere chose, and no data
    # layer sorts on a facet, so the click count is a column.
    test "the click count becomes the rank" do
      Fill.stations([station(%{click_count: 900})])

      assert [%{rank: 900}] = Playback.items_of_source!("internet-radio")
    end

    test "an HLS station names that transport" do
      Fill.stations([station(%{hls?: true})])

      assert [%{transport: :hls}] = Playback.items_of_source!("internet-radio")
    end

    # The service reports `OGG` for each codec inside that container, so this is a
    # claim and not the last word. `MyHiFi.Source.InternetRadio.resolve/1` reads the
    # first page of the stream at the time of play.
    test "a codec that the service does not name gives unknown" do
      Fill.stations([station(%{codec: "something else"})])

      assert [%{format: :unknown}] = Playback.items_of_source!("internet-radio")
    end

    test "a second run updates the row and writes no second one" do
      Fill.stations([station(%{remote_id: "one", title: "First"})])
      Fill.stations([station(%{remote_id: "one", title: "Second"})])

      assert [item] = Playback.items_of_source!("internet-radio")
      assert item.title == "Second"
      assert Ash.count!(Item) == 1
    end

    # A service knows nothing of what a person did, and `upsert` accepts none of it.
    test "a second run leaves a mark and a place alone" do
      Fill.stations([station(%{remote_id: "one"})])
      [item] = Playback.items_of_source!("internet-radio")
      {:ok, _marked} = Playback.set_favourite(item)

      Fill.stations([station(%{remote_id: "one", title: "A new title"})])

      assert {:ok, read} = Playback.get_item(item.id)
      assert read.title == "A new title"
      assert read.favourite? == true
    end
  end

  describe "the facets of a station" do
    test "a country, a language, a bitrate and each tag become facets" do
      Fill.stations([station()])

      assert values_of("country") == ["NZ"]
      assert values_of("language") == ["english"]
      assert values_of("bitrate") == [128]
      assert values_of("tag") == ["news", "talk"]
    end

    # This is the point of the join. One country row serves every station of it.
    test "many stations of one country name one facet row" do
      Fill.stations(Enum.map(1..5, fn n -> station(%{remote_id: "s#{n}"}) end))

      assert [country] = Playback.facets_of_key!("country")
      assert Ash.count!(Ash.Query.filter(ItemFacet, facet_id == ^country.id)) == 5
    end

    # The service gives the tags of each station as the publisher typed them, so `Rock`
    # and `rock` are two spellings of one tag. One facet holds both.
    test "a tag goes to lower case, so one facet holds each spelling of it" do
      Fill.stations([station(%{remote_id: "one", tags: ["Classic Rock"]})])
      Fill.stations([station(%{remote_id: "two", tags: ["classic rock"]})])

      assert values_of("tag") == ["classic rock"]
      assert [facet] = Playback.facets_of_key!("tag")
      assert Ash.count!(Ash.Query.filter(ItemFacet, facet_id == ^facet.id)) == 2
    end

    test "a bitrate keeps its type, so a filter compares it as a number" do
      Fill.stations([station(%{remote_id: "loud", bitrate: 320})])
      Fill.stations([station(%{remote_id: "quiet", bitrate: 64})])

      assert [found] =
               Item
               |> Ash.Query.filter(exists(facets, key == "bitrate" and value[:value] > 200))
               |> Ash.read!()

      assert found.source_ref == "loud"
    end

    test "a station with no country and no tags writes none of those" do
      Fill.stations([station(%{country_code: "", tags: [], language: nil})])

      assert values_of("country") == []
      assert values_of("tag") == []
      assert values_of("language") == []
      assert Ash.count!(Item) == 1
    end

    test "a second run makes no second link" do
      Fill.stations([station(%{remote_id: "one"})])
      before = Ash.count!(ItemFacet)

      Fill.stations([station(%{remote_id: "one"})])

      assert Ash.count!(ItemFacet) == before
    end
  end

  describe "tidying" do
    test "it removes a facet that no station holds any more" do
      Fill.stations([station(%{remote_id: "one"})])
      [item] = Playback.items_of_source!("internet-radio")

      assert :ok = Playback.destroy_item(item)

      # A country, a language, a bitrate and two tags.
      assert Fill.tidy() == 5
      assert Ash.count!(Facet) == 0
    end

    test "it keeps a facet that a station still holds" do
      Fill.stations([station()])

      assert Fill.tidy() == 0
      assert values_of("country") == ["NZ"]
    end
  end

  test "an empty list writes nothing" do
    assert Fill.stations([]) == 0
    assert Ash.count!(Item) == 0
  end
end
