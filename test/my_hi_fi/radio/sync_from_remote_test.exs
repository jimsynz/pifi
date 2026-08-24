defmodule MyHiFi.Radio.Station.SyncFromRemoteTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Radio
  alias MyHiFi.Radio.RadioBrowser
  alias MyHiFi.Radio.Station.SyncFromRemote
  alias MyHiFi.Settings

  defp station(attributes) do
    Map.merge(
      %{
        "stationuuid" => "remote-#{System.unique_integer([:positive])}",
        "name" => "A station",
        "url_resolved" => "http://example.test/stream.mp3",
        "codec" => "MP3",
        "bitrate" => 128,
        "hls" => 0,
        "countrycode" => "NZ",
        "language" => "english",
        "tags" => "news",
        "clickcount" => 1
      },
      attributes
    )
  end

  defp stub_country(stations_by_country) do
    Req.Test.stub(RadioBrowser, fn conn ->
      country = conn.request_path |> String.split("/") |> List.last()

      case Map.fetch(stations_by_country, country) do
        {:ok, stations} -> Req.Test.json(conn, stations)
        :error -> Plug.Conn.send_resp(conn, 404, "no such country")
      end
    end)
  end

  describe "configured_countries/0" do
    test "gives New Zealand when a person has chosen none" do
      assert ["NZ"] = SyncFromRemote.configured_countries()
    end

    test "reads the list that a person chose" do
      Settings.put!(SyncFromRemote.countries_key(), "NZ, AU ,GB")

      assert ["NZ", "AU", "GB"] = SyncFromRemote.configured_countries()
    end
  end

  describe "sync_from_remote" do
    test "writes the stations of the default country" do
      stub_country(%{"NZ" => [station(%{"name" => "RNZ National"})]})

      assert %{written: 1, failed: [], countries: ["NZ"]} = Radio.sync_stations_from_remote!()
      assert [%{title: "RNZ National", country_code: "NZ"}] = Radio.list_stations!()
    end

    test "follows the country list of the settings" do
      Settings.put!(SyncFromRemote.countries_key(), "NZ,AU")

      stub_country(%{
        "NZ" => [station(%{"name" => "Kiwi FM"})],
        "AU" => [station(%{"name" => "Aussie FM", "countrycode" => "AU"})]
      })

      assert %{written: 2, countries: ["NZ", "AU"]} = Radio.sync_stations_from_remote!()
      assert 2 = length(Radio.list_stations!())
    end

    test "notes a country that the service refused, and keeps the rest" do
      Settings.put!(SyncFromRemote.countries_key(), "NZ,ZZ")
      stub_country(%{"NZ" => [station(%{})]})

      assert %{written: 1, failed: [{"ZZ", {:unexpected_status, 404}}]} =
               Radio.sync_stations_from_remote!()
    end

    test "leaves out a station that cannot play" do
      stub_country(%{
        "NZ" => [
          station(%{"name" => "Good"}),
          station(%{"name" => "No address", "url_resolved" => nil, "url" => nil}),
          station(%{"name" => "", "url_resolved" => "http://x.test/s"})
        ]
      })

      assert %{written: 1} = Radio.sync_stations_from_remote!()
      assert [%{title: "Good"}] = Radio.list_stations!()
    end

    test "a second run updates and does not duplicate" do
      one = station(%{"name" => "First name", "bitrate" => 64})
      stub_country(%{"NZ" => [one]})
      assert %{written: 1} = Radio.sync_stations_from_remote!()

      stub_country(%{"NZ" => [Map.merge(one, %{"name" => "Second name", "bitrate" => 128})]})
      assert %{written: 1} = Radio.sync_stations_from_remote!()

      assert [%{title: "Second name", bitrate: 128}] = Radio.list_stations!()
    end

    test "a second run keeps what belongs to the person" do
      one = station(%{"name" => "Keep me"})
      stub_country(%{"NZ" => [one]})
      Radio.sync_stations_from_remote!()

      [written] = Radio.list_stations!()
      Radio.set_favourite!(written)

      stub_country(%{"NZ" => [Map.put(one, "name", "New name")]})
      Radio.sync_stations_from_remote!()

      assert [%{title: "New name", favourite?: true}] = Radio.list_stations!()
    end

    test "takes the countries as an argument" do
      stub_country(%{"GB" => [station(%{"name" => "BBC", "countrycode" => "GB"})]})

      assert %{written: 1, countries: ["GB"]} =
               Radio.sync_stations_from_remote!(%{countries: ["GB"]})
    end

    test "it asks for nothing when the internet radio source is out of use" do
      stub_country(%{"NZ" => [station(%{})]})
      MyHiFi.Source.enable(MyHiFi.Source.InternetRadio, false)

      on_exit(fn ->
        {:ok, setting} =
          Settings.fetch(MyHiFi.Source.enabled_key(MyHiFi.Source.InternetRadio))

        Settings.delete!(setting)
      end)

      assert %{written: 0, skipped?: true} = Radio.sync_stations_from_remote!()
      assert Radio.list_stations!() == []
    end

    test "the stations it wrote are findable by title and by tag" do
      stub_country(%{
        "NZ" => [station(%{"name" => "The Rock", "tags" => "classic rock,music"})]
      })

      Radio.sync_stations_from_remote!()

      assert [%{title: "The Rock"}] = Radio.search_stations!("rock")
      assert [%{title: "The Rock"}] = Radio.search_stations!("music")
    end
  end
end
