defmodule PiFiWeb.TitleTest do
  use ExUnit.Case, async: true

  doctest PiFiWeb.Title

  alias PiFiWeb.Title

  defp idle(extra \\ %{}) do
    Map.merge(%{playing?: false, paused?: false, standby?: false}, extra)
  end

  defp playing(extra) do
    Map.merge(%{playing?: true, paused?: false, standby?: false, position_ms: 0}, extra)
  end

  describe "a device that is doing nothing" do
    test "it names the device and the page" do
      assert Title.compose("Living Room", "Plex", idle()) == "Living Room — Plex"
    end

    test "a page that says nothing leaves the device alone" do
      assert Title.compose("Living Room", nil, idle()) == "Living Room"
    end

    # A device in standby is one that a person turned off, and a tab that still named
    # the record would read as a device that is still on.
    test "standby outranks the page and the track" do
      state = playing(%{standby?: true, item: %{title: "DNH", duration_ms: 147_000}})

      assert Title.compose("Living Room", "Plex", state) == "Living Room — Standby"
    end
  end

  describe "a track that is playing" do
    test "it says the verb, the track, the place in it and the source" do
      state =
        playing(%{
          item: %{title: "DNH", subtitle: "Tove Lo", duration_ms: 147_000},
          position_ms: 56_000,
          source: PiFi.Source.Plex
        })

      assert Title.compose("Living Room", "Settings", state) ==
               "Living Room — Playing DNH · Tove Lo (0:56/2:27) from Plex"
    end

    # A person who left this on the settings page and started a record wants the record.
    test "it replaces the page rather than joining it" do
      state = playing(%{item: %{title: "DNH", duration_ms: 147_000}, position_ms: 0})

      refute Title.compose("Living Room", "Settings", state) =~ "Settings"
    end

    test "a paused track says so and keeps its place" do
      state =
        playing(%{
          playing?: false,
          paused?: true,
          item: %{title: "DNH", subtitle: "Tove Lo", duration_ms: 147_000},
          position_ms: 56_000
        })

      assert Title.compose("Kitchen", nil, state) == "Kitchen — Paused DNH · Tove Lo (0:56/2:27)"
    end

    test "a track with no second line names the track alone" do
      state = playing(%{item: %{title: "Interval signal", duration_ms: 60_000}})

      assert Title.compose("Kitchen", nil, state) ==
               "Kitchen — Playing Interval signal (0:00/1:00)"
    end

    # An episode of two hours needs them and a song of three minutes reads worse for
    # the two leading zeros.
    test "hours appear only when there are hours" do
      state =
        playing(%{item: %{title: "A long show", duration_ms: 7_530_000}, position_ms: 3_661_000})

      assert Title.compose("Kitchen", nil, state) ==
               "Kitchen — Playing A long show (1:01:01/2:05:30)"
    end
  end

  describe "a live stream" do
    # Internet radio sends a title over ICY and knows no artist.
    test "the stream title is the track" do
      state = playing(%{stream_title: "Tove Lo - DNH", source: PiFi.Source.InternetRadio})

      assert Title.compose("Kitchen", nil, state) ==
               "Kitchen — Playing Tove Lo - DNH from Internet radio"
    end

    # A counter against no total reads as a fault rather than as a fact.
    test "it carries no counter, because it has no end" do
      state = playing(%{stream_title: "Tove Lo - DNH", position_ms: 56_000})

      refute Title.compose("Kitchen", nil, state) =~ "0:56"
    end

    test "a stream with a title outranks the item it came from" do
      state =
        playing(%{
          stream_title: "Tove Lo - DNH",
          item: %{title: "RNZ National", subtitle: "Radio New Zealand"}
        })

      assert Title.compose("Kitchen", nil, state) =~ "Tove Lo - DNH"
      refute Title.compose("Kitchen", nil, state) =~ "RNZ National"
    end
  end

  # **A title is not worth an error page.** The player reports what it holds, and a
  # state that is missing a field must give a shorter title rather than raise.
  describe "a state that is not complete" do
    test "playing with no track at all falls back to the page" do
      assert Title.compose("Kitchen", "Plex", playing(%{})) == "Kitchen — Plex"
    end

    test "an empty state names the device" do
      assert Title.compose("Kitchen", nil, %{}) == "Kitchen"
    end

    # Podcasts put a date and a length in `subtitle`, and radio puts a codec. Neither
    # is an artist, so neither may be written as one.
    test "a second line is never claimed as an artist" do
      state = playing(%{item: %{title: "RNZ National", subtitle: "MP3, 128 kbps"}})

      assert Title.compose("Kitchen", nil, state) ==
               "Kitchen — Playing RNZ National · MP3, 128 kbps"

      refute Title.compose("Kitchen", nil, state) =~ " by "
    end

    test "a source this build does not hold names no source" do
      state = playing(%{item: %{title: "DNH"}, source: PiFi.Source.NotABuiltSource})

      assert Title.compose("Kitchen", nil, state) == "Kitchen — Playing DNH"
    end
  end
end
