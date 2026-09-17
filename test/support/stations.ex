defmodule PiFi.Test.Stations do
  @moduledoc """
  Seed a station the way that the sync job does.

  `PiFi.Source.InternetRadio` reads `PiFi.Playback.Item`, so a test that wants a
  station must write one through `PiFi.Radio.Fill`. A test that writes a
  `PiFi.Radio.Station` row seeds a table that the source no longer reads.

  It gives the item, so a caller names it with `{:station, item.id}`.
  """

  require Ash.Query

  alias PiFi.Playback.Item
  alias PiFi.Radio.Fill

  @doc "Write one station into the catalogue, and give its item."
  @spec create(map()) :: Item.t()
  def create(overrides \\ %{}) do
    attributes = Map.merge(defaults(), overrides)

    Fill.stations([attributes])

    Item
    |> Ash.Query.filter(source_ref == ^attributes.remote_id)
    |> Ash.read_one!()
  end

  @doc "What `PiFi.Radio.RadioBrowser.to_station/1` gives, with nothing unusual in it."
  @spec defaults() :: map()
  def defaults do
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
    }
  end
end
