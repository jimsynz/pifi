defmodule MyHiFi.Source.InternetRadioTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Radio
  alias MyHiFi.Source.InternetRadio

  defp station(overrides \\ %{}) do
    defaults = %{
      remote_id: "remote-#{System.unique_integer([:positive])}",
      title: "Station #{System.unique_integer([:positive])}",
      stream_url: "http://example.test/stream.mp3",
      codec: "MP3",
      bitrate: 128,
      hls?: false,
      country_code: "NZ",
      tags: ["news"],
      click_count: 0
    }

    Radio.upsert_station_from_remote!(Map.merge(defaults, overrides))
  end

  describe "the source itself" do
    test "names itself and gives a root" do
      assert InternetRadio.title() == "Internet radio"
      assert InternetRadio.root() == :root
    end
  end

  describe "browse/2 at the root" do
    test "gives the three branches, and no more pages" do
      assert {:ok, %{entries: entries, cursor: nil}} = InternetRadio.browse(:root)

      assert [
               {:container, %{ref: :favourites, title: "Favourites"}},
               {:container, %{ref: :countries, title: "Countries"}},
               {:container, %{ref: :tags, title: "Tags"}}
             ] = entries
    end
  end

  describe "browse/2 for countries" do
    test "lists each country once, in order" do
      station(%{country_code: "NZ"})
      station(%{country_code: "NZ"})
      station(%{country_code: "AU"})

      assert {:ok, %{entries: entries}} = InternetRadio.browse(:countries)

      assert [
               {:container, %{ref: {:country, "AU"}, title: "AU"}},
               {:container, %{ref: {:country, "NZ"}, title: "NZ"}}
             ] = entries
    end

    test "leaves out a station with no country" do
      station(%{country_code: nil})
      station(%{country_code: "NZ"})

      assert {:ok, %{entries: [{:container, %{ref: {:country, "NZ"}}}]}} =
               InternetRadio.browse(:countries)
    end

    test "lists the stations of one country, the best known first" do
      station(%{title: "Quiet", country_code: "NZ", click_count: 1})
      station(%{title: "Popular", country_code: "NZ", click_count: 20})
      station(%{title: "Elsewhere", country_code: "AU"})

      assert {:ok, %{entries: entries}} = InternetRadio.browse({:country, "NZ"})

      assert [
               {:track, %{title: "Popular"}},
               {:track, %{title: "Quiet"}}
             ] = entries
    end
  end

  describe "browse/2 for tags" do
    test "lists each tag once, in order" do
      station(%{tags: ["rock", "news"]})
      station(%{tags: ["rock"]})

      assert {:ok, %{entries: entries}} = InternetRadio.browse(:tags)

      assert [
               {:container, %{ref: {:tag, "news"}}},
               {:container, %{ref: {:tag, "rock"}}}
             ] = entries
    end

    test "lists the stations that carry one tag" do
      station(%{title: "Rocker", tags: ["rock"]})
      station(%{title: "Talker", tags: ["talk"]})

      assert {:ok, %{entries: [{:track, %{title: "Rocker"}}]}} =
               InternetRadio.browse({:tag, "rock"})
    end

    test "matches a tag in full and not in part" do
      station(%{title: "Classic", tags: ["classic rock"]})

      assert {:ok, %{entries: []}} = InternetRadio.browse({:tag, "rock"})
      assert {:ok, %{entries: [_one]}} = InternetRadio.browse({:tag, "classic rock"})
    end

    test "ignores the case of a tag" do
      station(%{title: "Loud", tags: ["Heavy Metal"]})

      assert {:ok, %{entries: [{:track, %{title: "Loud"}}]}} =
               InternetRadio.browse({:tag, "heavy metal"})
    end
  end

  describe "browse/2 for favourites" do
    test "lists only what a person marked" do
      kept = station(%{title: "Kept"})
      _other = station(%{title: "Not kept"})
      Radio.set_favourite!(kept)

      assert {:ok, %{entries: [{:track, %{title: "Kept"}}]}} =
               InternetRadio.browse(:favourites)
    end
  end

  describe "browse/2 with an unknown container" do
    test "gives an error and does not fail" do
      assert {:error, {:no_such_container, :nonsense}} = InternetRadio.browse(:nonsense)
    end
  end

  describe "a track" do
    test "has no length, because a radio stream is live" do
      station()

      assert {:ok, %{entries: [{:track, %{duration_ms: nil}}]}} =
               InternetRadio.browse({:country, "NZ"})
    end

    test "names the codec and the bitrate under the title" do
      station(%{codec: "AAC", bitrate: 64})

      assert {:ok, %{entries: [{:track, %{subtitle: "AAC, 64 kbps"}}]}} =
               InternetRadio.browse({:country, "NZ"})
    end

    test "names the codec alone when the service knows no bitrate" do
      station(%{codec: "MP3", bitrate: 0})

      assert {:ok, %{entries: [{:track, %{subtitle: "MP3"}}]}} =
               InternetRadio.browse({:country, "NZ"})
    end

    test "carries the artwork of the station" do
      station(%{artwork_url: "http://example.test/logo.png"})

      assert {:ok, %{entries: [{:track, %{artwork: "http://example.test/logo.png"}}]}} =
               InternetRadio.browse({:country, "NZ"})
    end
  end

  describe "paging" do
    test "gives a cursor for the next page, and none for the last" do
      for index <- 1..5, do: station(%{title: "Station #{index}", click_count: 100 - index})

      assert {:ok, %{entries: first, cursor: 2}} =
               InternetRadio.browse({:country, "NZ"}, limit: 2)

      assert 2 = length(first)

      assert {:ok, %{entries: _second, cursor: 4}} =
               InternetRadio.browse({:country, "NZ"}, limit: 2, cursor: 2)

      assert {:ok, %{entries: last, cursor: nil}} =
               InternetRadio.browse({:country, "NZ"}, limit: 2, cursor: 4)

      assert 1 = length(last)
    end
  end

  describe "search/2" do
    test "finds a station by title or by tag" do
      station(%{title: "Newstalk ZB", tags: ["news"]})
      station(%{title: "The Sound", tags: ["classic rock"]})

      assert {:ok, %{entries: [{:track, %{title: "Newstalk ZB"}}]}} =
               InternetRadio.search("newstalk")

      assert {:ok, %{entries: [{:track, %{title: "The Sound"}}]}} =
               InternetRadio.search("classic")
    end
  end

  describe "resolve/1" do
    test "gives everything that the player needs" do
      one = station(%{stream_url: "http://example.test/live.mp3", codec: "MP3"})

      assert {:ok, playable} = InternetRadio.resolve({:station, one.id})

      assert %{
               uri: "http://example.test/live.mp3",
               headers: [],
               transport: :http,
               container: :none,
               format: :mp3,
               live?: true
             } = playable
    end

    test "gives an error for a station that is absent" do
      assert {:error, _reason} = InternetRadio.resolve({:station, Ash.UUID.generate()})
    end

    test "gives an error for something that is not a track" do
      assert {:error, {:not_a_track, :countries}} = InternetRadio.resolve(:countries)
    end
  end

  describe "format/1" do
    test "gives the codec of an HLS station, because the playlist decides the rest" do
      assert :aac = InternetRadio.format(%{hls?: true, codec: "AAC"})
    end

    test "reads each codec that the service reports" do
      for {codec, expected} <- [
            {"MP3", :mp3},
            {"mp3", :mp3},
            {"AAC", :aac},
            {"AAC+", :aac},
            {"FLAC", :flac},
            {"OGG", :ogg},
            {"UNKNOWN", :unknown},
            {"something else", :unknown}
          ] do
        assert expected == InternetRadio.format(%{hls?: false, codec: codec})
      end
    end

    test "reads no codec at all" do
      assert :unknown = InternetRadio.format(%{hls?: false, codec: nil})
    end
  end

  describe "favourite/2" do
    test "makes a station a favourite, and removes that mark" do
      created = station(%{title: "Concert"})
      ref = {:station, created.id}

      assert :ok = InternetRadio.favourite(ref, true)
      assert {:ok, %{favourite?: true}} = InternetRadio.track(ref)

      assert {:ok, %{entries: [{:track, %{title: "Concert"}}]}} =
               InternetRadio.browse(:favourites)

      assert :ok = InternetRadio.favourite(ref, false)
      assert {:ok, %{favourite?: false}} = InternetRadio.track(ref)
      assert {:ok, %{entries: []}} = InternetRadio.browse(:favourites)
    end

    test "gives an error for a container" do
      assert {:error, {:not_a_track, :countries}} = InternetRadio.favourite(:countries, true)
    end

    test "gives an error for a station that is not there" do
      assert {:error, _reason} = InternetRadio.favourite({:station, Ash.UUID.generate()}, true)
    end
  end

  describe "naming a ref" do
    test "a station ref goes to a name and back" do
      created = station(%{})
      ref = {:station, created.id}

      assert {:ok, name} = InternetRadio.ref_to_string(ref)
      assert name == "station:" <> created.id
      assert {:ok, ^ref} = InternetRadio.ref_from_string(name)
    end

    test "a container gives an error, because the player stores the tracks only" do
      for ref <- [:root, :favourites, :countries, :tags, {:country, "NZ"}, {:tag, "jazz"}] do
        assert {:error, :cannot_name} = InternetRadio.ref_to_string(ref)
      end
    end

    test "a name that this source did not write gives an error" do
      for name <- ["", "rubbish", "station:", "station:not-a-uuid", "country:NZ"] do
        assert {:error, :not_a_name} = InternetRadio.ref_from_string(name)
      end
    end
  end

  describe "the whole tree" do
    test "a caller walks from the root to a playable stream" do
      station(%{title: "RNZ National", country_code: "NZ", stream_url: "http://rnz.test/s.mp3"})

      {:ok, %{entries: root}} = InternetRadio.browse(InternetRadio.root())

      {:container, %{ref: countries}} =
        Enum.find(root, &match?({:container, %{ref: :countries}}, &1))

      {:ok, %{entries: [{:container, %{ref: country}} | _]}} = InternetRadio.browse(countries)

      {:ok, %{entries: [{:track, %{ref: track, title: title}} | _]}} =
        InternetRadio.browse(country)

      assert title == "RNZ National"
      assert {:ok, %{uri: "http://rnz.test/s.mp3", live?: true}} = InternetRadio.resolve(track)
    end
  end
end
