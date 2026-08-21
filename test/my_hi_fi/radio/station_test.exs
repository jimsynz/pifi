defmodule MyHiFi.Radio.StationTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Radio

  defp remote_station(overrides \\ %{}) do
    defaults = %{
      remote_id: "remote-#{System.unique_integer([:positive])}",
      title: "Station #{System.unique_integer([:positive])}",
      stream_url: "http://example.test/stream.mp3",
      codec: "MP3",
      bitrate: 128,
      hls?: false,
      country_code: "NZ",
      language: "english",
      tags: ["news"],
      artwork_url: nil,
      click_count: 0
    }

    Radio.upsert_station_from_remote!(Map.merge(defaults, overrides))
  end

  describe "upsert_from_remote" do
    test "writes a station" do
      station = remote_station(%{title: "RNZ National", codec: "MP3"})

      assert station.title == "RNZ National"
      assert station.codec == "MP3"
      assert station.favourite? == false
      assert station.tags == ["news"]
    end

    test "updates the same station instead of writing a second row" do
      first = remote_station(%{title: "The Rock", bitrate: 64})

      second =
        Radio.upsert_station_from_remote!(%{
          remote_id: first.remote_id,
          title: "The Rock",
          stream_url: "http://example.test/rock.aac",
          bitrate: 128
        })

      assert second.id == first.id
      assert second.bitrate == 128
      assert [_only_one] = Radio.list_stations!(query: [filter: [remote_id: first.remote_id]])
    end

    test "leaves what belongs to the person alone" do
      station = remote_station()
      Radio.set_favourite!(station)
      played = Radio.record_play!(Radio.get_station!(station.id))

      refreshed =
        Radio.upsert_station_from_remote!(%{
          remote_id: station.remote_id,
          title: "A new title from the service",
          stream_url: station.stream_url
        })

      assert refreshed.title == "A new title from the service"
      assert refreshed.favourite? == true
      assert refreshed.last_played_at == played.last_played_at
    end

    test "writes more than one station with no remote id" do
      one = Radio.upsert_station_from_remote!(%{title: "Mine", stream_url: "http://a.test/s"})

      two =
        Radio.upsert_station_from_remote!(%{title: "Also mine", stream_url: "http://b.test/s"})

      refute one.id == two.id
    end
  end

  describe "search" do
    test "finds a station by part of its title" do
      remote_station(%{title: "Newstalk ZB"})
      remote_station(%{title: "The Sound"})

      assert [%{title: "Newstalk ZB"}] = Radio.search_stations!("stalk")
    end

    test "finds a station by tag" do
      remote_station(%{title: "One", tags: ["classic rock", "oldies"]})
      remote_station(%{title: "Two", tags: ["news"]})

      assert [%{title: "One"}] = Radio.search_stations!("rock")
    end

    test "ignores the case of a tag" do
      remote_station(%{title: "Loud", tags: ["Heavy Metal"]})

      assert [%{title: "Loud"}] = Radio.search_stations!("metal")
    end

    test "gives the most popular station first" do
      remote_station(%{title: "Rock A", click_count: 3})
      remote_station(%{title: "Rock B", click_count: 11})

      assert [%{title: "Rock B"}, %{title: "Rock A"}] = Radio.search_stations!("Rock")
    end

    test "ignores the case of a title" do
      remote_station(%{title: "RNZ National"})

      assert [%{title: "RNZ National"}] = Radio.search_stations!("rnz")
      assert [%{title: "RNZ National"}] = Radio.search_stations!("NATIONAL")
    end

    test "treats a wildcard in the text of the person as a letter" do
      remote_station(%{title: "Plain FM"})
      remote_station(%{title: "100% Hits"})

      assert [%{title: "100% Hits"}] = Radio.search_stations!("100%")
      assert [] = Radio.search_stations!("%%%")
    end

    test "gives nothing when nothing matches" do
      remote_station(%{title: "Quiet", tags: ["talk"]})

      assert [] = Radio.search_stations!("nothing here")
    end
  end

  describe "favourites" do
    test "lists only what a person marked, by title" do
      keep_second = remote_station(%{title: "Zed FM"})
      keep_first = remote_station(%{title: "Alpha FM"})
      _ignore = remote_station(%{title: "Not marked"})

      Radio.set_favourite!(keep_first)
      Radio.set_favourite!(keep_second)

      assert [%{title: "Alpha FM"}, %{title: "Zed FM"}] = Radio.favourite_stations!()
    end

    test "clear_favourite removes it from the list" do
      station = remote_station()
      Radio.set_favourite!(station)
      assert [_one] = Radio.favourite_stations!()

      Radio.clear_favourite!(Radio.get_station!(station.id))
      assert [] = Radio.favourite_stations!()
    end
  end

  describe "record_play" do
    test "notes the time" do
      station = remote_station()
      assert station.last_played_at == nil

      played = Radio.record_play!(station)
      assert %DateTime{} = played.last_played_at
    end
  end
end
