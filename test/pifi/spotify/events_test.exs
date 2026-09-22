defmodule PiFi.Spotify.EventsTest do
  use ExUnit.Case, async: true

  doctest PiFi.Spotify.Events

  alias PiFi.Spotify.Events

  defp block(lines) do
    Enum.join([Events.opening()] ++ lines ++ [Events.closing(), ""], "\n")
  end

  describe "taking blocks out of a stream" do
    test "two blocks in one read come back in order" do
      buffer = block(["PLAYER_EVENT=playing"]) <> block(["PLAYER_EVENT=paused"])

      assert {[%{"PLAYER_EVENT" => "playing"}, %{"PLAYER_EVENT" => "paused"}], ""} =
               Events.take(buffer)
    end

    # A port hands over whatever has arrived, and a block can be split across two reads.
    test "a block split across two reads is one event" do
      whole = block(["SINK_STATUS=running"])
      {at, _} = {div(byte_size(whole), 2), nil}
      <<first::binary-size(at), second::binary>> = whole

      assert {[], rest} = Events.take(first)
      assert {[%{"SINK_STATUS" => "running"}], ""} = Events.take(rest <> second)
    end

    # **The environment of the daemon is the whole environment**, and `PATH` is not an
    # event.
    test "it keeps only the names that are worth keeping" do
      buffer = block(["PATH=/usr/bin", "HOME=/root", "SINK_STATUS=closed"])

      assert {[event], ""} = Events.take(buffer)
      assert event == %{"SINK_STATUS" => "closed"}
    end

    # A value may hold an `=`, and splitting on every one would lose the rest of it.
    test "a value that holds an equals sign survives" do
      buffer = block(["NAME=2 + 2 = 4"])

      assert {[%{"NAME" => "2 + 2 = 4"}], ""} = Events.take(buffer)
    end

    # **Noise must not accumulate.** A daemon that writes to standard output for some
    # other reason would otherwise grow the buffer without bound.
    test "bytes that are not inside a block are dropped rather than held" do
      assert {[], ""} = Events.take("something else entirely\n")
    end

    test "an empty read gives nothing and holds nothing" do
      assert {[], ""} = Events.take("")
    end
  end

  describe "what an event means" do
    test "the three sink states are the handover" do
      assert Events.sink(%{"SINK_STATUS" => "running"}) == :running
      assert Events.sink(%{"SINK_STATUS" => "temporarily_closed"}) == :paused
      assert Events.sink(%{"SINK_STATUS" => "closed"}) == :closed
    end

    test "a status this firmware does not know says nothing" do
      assert Events.sink(%{"SINK_STATUS" => "something_new"}) == nil
    end

    # `ARTISTS` holds one name per line, and a card draws them on one line.
    test "more than one artist reads as a list" do
      event = %{"NAME" => "DNH", "ARTISTS" => "Tove Lo\nSomebody Else"}

      assert %{artists: "Tove Lo, Somebody Else"} = Events.track(event)
    end

    # `COVERS` holds one address for each size, largest first.
    test "the artwork is the first address of the covers" do
      event = %{"NAME" => "DNH", "COVERS" => "https://big.test/a.jpg\nhttps://small.test/b.jpg"}

      assert %{artwork: "https://big.test/a.jpg"} = Events.track(event)
    end

    test "a duration that is not a number is no duration" do
      assert %{duration_ms: nil} = Events.track(%{"NAME" => "DNH", "DURATION_MS" => "soon"})
    end

    test "an event with no position says nothing about one" do
      assert Events.position(%{"PLAYER_EVENT" => "stopped"}) == nil
    end
  end
end
