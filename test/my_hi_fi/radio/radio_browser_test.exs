defmodule MyHiFi.Radio.RadioBrowserTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Radio.RadioBrowser

  describe "to_station/1" do
    test "maps a station of the service" do
      assert %{
               remote_id: "abc-123",
               title: "RNZ National",
               stream_url: "http://radionz-ice.streamguys.com/national.mp3",
               codec: "MP3",
               bitrate: 128,
               hls?: false,
               country_code: "NZ",
               language: "english",
               tags: ["news", "talk"],
               artwork_url: "http://example.test/logo.png",
               click_count: 11
             } =
               RadioBrowser.to_station(%{
                 "stationuuid" => "abc-123",
                 "name" => "  RNZ National  ",
                 "url" => "http://redirect.test/national",
                 "url_resolved" => "http://radionz-ice.streamguys.com/national.mp3",
                 "codec" => "MP3",
                 "bitrate" => 128,
                 "hls" => 0,
                 "countrycode" => "NZ",
                 "language" => "english",
                 "tags" => "news, talk",
                 "favicon" => "http://example.test/logo.png",
                 "clickcount" => 11
               })
    end

    test "marks an HLS station" do
      assert %{hls?: true} = RadioBrowser.to_station(%{"hls" => 1})
    end

    test "uses the address that a person gave when the service resolved none" do
      assert %{stream_url: "http://only.test/s"} =
               RadioBrowser.to_station(%{"url" => "http://only.test/s"})
    end

    test "removes a repeated tag and an empty one" do
      assert %{tags: ["rock", "pop"]} =
               RadioBrowser.to_station(%{"tags" => "rock, , pop,rock, "})
    end

    test "gives no tags when the service gives none" do
      assert %{tags: []} = RadioBrowser.to_station(%{})
    end

    test "treats an empty logo as absent" do
      assert %{artwork_url: nil} = RadioBrowser.to_station(%{"favicon" => ""})
    end

    test "counts no clicks when the service gives none" do
      assert %{click_count: 0} = RadioBrowser.to_station(%{})
    end
  end

  describe "stations_by_country/1" do
    setup do
      Req.Test.verify_on_exit!()
    end

    test "asks for the country and names itself" do
      Req.Test.stub(RadioBrowser, fn conn ->
        assert conn.request_path == "/json/stations/bycountrycodeexact/NZ"
        assert {"user-agent", agent} = List.keyfind(conn.req_headers, "user-agent", 0)
        assert agent =~ "MyHiFi"

        Req.Test.json(conn, [
          %{"stationuuid" => "one", "name" => "One", "url_resolved" => "http://a.test/s"}
        ])
      end)

      assert {:ok, [%{remote_id: "one", title: "One"}]} = RadioBrowser.stations_by_country("NZ")
    end

    test "gives an error for an unexpected status" do
      Req.Test.stub(RadioBrowser, fn conn -> Plug.Conn.send_resp(conn, 503, "busy") end)

      assert {:error, {:unexpected_status, 503}} = RadioBrowser.stations_by_country("NZ")
    end
  end
end
