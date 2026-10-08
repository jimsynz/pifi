defmodule PiFiWeb.BrowsingTest do
  @moduledoc """
  Where the browser opens.

  **Navigation and selection used to be one setting.** `PiFi.Source.choose/1` was named
  for a switch and used as a bookmark: the pages wrote it on every navigation and the
  Plex companion wrote it when a controller started playing, so a cast moved the
  browser's bookmark and reading about a station moved the device's switch. The tests
  of that function lived in `PiFi.SourceTest` and most of them are here now.
  """

  use PiFi.DataCase, async: false

  alias PiFi.Playback
  alias PiFi.Settings
  alias PiFi.Source
  alias PiFi.Test.PlayingPipeline
  alias PiFi.Test.SilentOutput
  alias PiFi.Test.Stations
  alias PiFiWeb.Browsing

  doctest PiFiWeb.Browsing

  setup do
    on_exit(fn ->
      PiFi.Player.stop()

      for key <- [Browsing.key() | Enum.map(Source.all(), &Source.enabled_key/1)] do
        case Settings.fetch(key) do
          {:ok, setting} -> Settings.delete!(setting)
          {:error, _reason} -> :ok
        end
      end
    end)

    :ok
  end

  defp playing_station do
    PlayingPipeline.use_it()
    SilentOutput.use_it()

    station = Stations.create(%{country_code: "NZ", title: "Playing FM"})

    PiFi.Event.subscribe(:player)
    assert {:ok, :ok} = Playback.play([station.id])
    assert_receive %PiFi.Event.Player.Started{}, 2000

    station
  end

  describe "the source a person was last reading" do
    test "a browser that nobody has used remembers none" do
      assert Browsing.last() == nil
    end

    test "a visit stays, and it survives a restart because it is a row" do
      Source.enable(Source.Podcasts, true)
      Browsing.visited(Source.Podcasts)

      assert Browsing.last() == Source.Podcasts
      assert {:ok, %{value: "podcasts"}} = Settings.fetch(Browsing.key())
    end

    # A move through the tree of one source costs no write, and the SD card lasts
    # longer for it.
    test "a second visit to the same source writes nothing" do
      Browsing.visited(Source.Podcasts)
      {:ok, first} = Settings.fetch(Browsing.key())

      Browsing.visited(Source.Podcasts)

      assert {:ok, ^first} = Settings.fetch(Browsing.key())
    end

    test "a source that a person took out of use is not remembered" do
      Browsing.visited(Source.Podcasts)
      Source.enable(Source.Podcasts, false)

      assert Browsing.last() == nil
    end

    # A firmware that drops a source leaves the name of it in the settings.
    test "a name that no source holds is not remembered" do
      Settings.put!(Browsing.key(), "a-source-that-went")

      assert Browsing.last() == nil
    end
  end

  describe "where the browser opens" do
    test "a device that plays nothing opens where a person was reading" do
      Source.enable(Source.Podcasts, true)
      Browsing.visited(Source.Podcasts)

      assert Browsing.landing() == Source.Podcasts
    end

    test "a device that nobody has used opens at the first source in use" do
      assert Browsing.landing() == List.first(Source.enabled())
    end

    # **A person who casts a record and then opens the browser is looking for that
    # record.** Where they were reading comes second.
    test "what the device plays comes before where a person was reading" do
      Source.enable(Source.Podcasts, true)
      Browsing.visited(Source.Podcasts)

      playing_station()

      assert Browsing.landing() == Source.InternetRadio
    end

    # `PiFi.Source.AirPlay` and `PiFi.Source.Spotify` answer `{:error, module}` from
    # `roots/0`, and landing a person on a page that says it browses nothing is worse
    # than landing them where they were.
    test "a source that browses nothing is skipped" do
      Source.enable(Source.Podcasts, true)
      Source.enable(Source.AirPlay, true)
      Browsing.visited(Source.Podcasts)

      assert {:ok, :ok} = Playback.play([Source.AirPlay.item().id])

      assert Browsing.landing() == Source.Podcasts
    end

    test "a device with no source in use opens at none" do
      for module <- Source.all(), do: Source.enable(module, false)

      assert Browsing.landing() == nil
    end
  end
end
