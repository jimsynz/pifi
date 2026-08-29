defmodule MyHiFi.Source.InternetRadioTest do
  use MyHiFi.DataCase, async: false

  require Ash.Query

  alias MyHiFi.Playback
  alias MyHiFi.Playback.Item
  alias MyHiFi.Radio.Fill
  alias MyHiFi.Source.InternetRadio

  # `MyHiFi.Radio.Fill` writes a station into the catalogue, and this source reads it
  # from there. A test therefore seeds the way that the sync job does.
  defp station(overrides \\ %{}) do
    attributes =
      Map.merge(
        %{
          remote_id: "remote-#{System.unique_integer([:positive])}",
          title: "Station #{System.unique_integer([:positive])}",
          stream_url: "http://example.test/stream.mp3",
          codec: "MP3",
          bitrate: 128,
          hls?: false,
          country_code: "NZ",
          language: nil,
          tags: ["news"],
          artwork_url: nil,
          click_count: 0
        },
        overrides
      )

    Fill.stations([attributes])

    Item
    |> Ash.Query.filter(source_ref == ^attributes.remote_id)
    |> Ash.read_one!()
  end

  describe "the source itself" do
    test "it names itself, and it says what a person calls its items" do
      assert InternetRadio.title() == "Internet radio"
      assert InternetRadio.kinds() == [track: "Stations"]
    end
  end

  describe "what this source holds" do
    # A radio stream is live, so there is no place to move to. Next and previous belong
    # to `MyHiFi.Playback.Queue` and not to a source.
    test "it holds a search, and no skip" do
      assert InternetRadio.capabilities() == [:search]
    end

    # A sync reads the whole list of a country, and no one station is a thing to read
    # again. The settings page holds the control that asks for the list.
    test "it reads no single container again" do
      refute :refresh in InternetRadio.capabilities()
    end
  end

  # A sync writes every station on to the card, so the query reaches no service and the
  # text of the person is not needed. `MyHiFiWeb.SearchLive` matches the text.
  describe "search/1" do
    test "it gives the stations of this source, and no station of another one" do
      station(%{title: "Newstalk ZB"})
      station(%{title: "The Sound"})

      MyHiFi.Playback.upsert_item!(%{
        source: "podcasts",
        source_ref: "a-show",
        title: "A show"
      })

      titles = "newstalk" |> InternetRadio.search() |> Ash.read!() |> Enum.map(& &1.title)

      assert Enum.sort(titles) == ["Newstalk ZB", "The Sound"]
    end
  end

  describe "resolve/1" do
    test "gives everything that the player needs" do
      one = station(%{stream_url: "http://example.test/live.mp3", codec: "MP3"})

      assert {:ok, playable} = InternetRadio.resolve(one)

      assert %{
               uri: "http://example.test/live.mp3",
               headers: [],
               transport: :http,
               container: :none,
               format: :mp3,
               live?: true
             } = playable
    end

    # `MyHiFi.Radio.CarryFavourites` writes a station that holds the mark of a person
    # and nothing else, and the next sync fills it. A person can press it first.
    test "a station that no sync has filled names the reason, and it does not raise" do
      one = station(%{})

      assert {:error, {:not_read_yet, title}} = InternetRadio.resolve(%{one | url: nil})
      assert title == one.title

      assert {:error, {:not_read_yet, _title}} = InternetRadio.resolve(%{one | format: nil})
    end

    # An address of `nil` reaches the network in the clause that reads a playlist, so
    # the guard must stand in front of it.
    test "a station of HLS that no sync has filled names the same reason" do
      one = station(%{})
      empty = %{one | url: nil, transport: :hls}

      assert {:error, {:not_read_yet, _title}} = InternetRadio.resolve(empty)
    end

    test "gives an error for a container, because a container never plays" do
      one = station(%{})
      {:ok, container} = Playback.get_item(one.id)
      container = %{container | kind: :container}

      assert {:error, {:not_a_track, _id}} = InternetRadio.resolve(container)
    end
  end

  # The two rules of the tree, from a branch of the source to something that plays. See
  # `MyHiFiWeb.BrowseLive` for the page that walks them.
  describe "the whole tree" do
    test "a caller walks from a branch to a playable stream" do
      station(%{title: "RNZ National", country_code: "NZ", stream_url: "http://rnz.test/s.mp3"})

      {"Countries", %{query: countries, kind: :facet}} =
        Enum.find(InternetRadio.roots(), &match?({"Countries", _listing}, &1))

      assert [%{value: %Ash.Union{value: "NZ"}}] = Ash.read!(countries)

      assert [item] =
               Item
               |> Ash.Query.filter(exists(facets, key == "country" and value == "NZ"))
               |> Ash.read!()

      assert item.title == "RNZ National"

      assert {:ok, %{uri: "http://rnz.test/s.mp3", live?: true}} =
               InternetRadio.resolve(item)
    end
  end
end
