defmodule PiFi.AirPlay.NowPlayingTest do
  @moduledoc """
  What a telephone says is playing, against the message a telephone really sent.

  The fixture below is the one a device at 192.168.5.50 posted on 2026-10-08, with the
  artwork shortened. There is no specification for this message, so a test written
  against anything else would be a test of a guess.
  """

  use ExUnit.Case, async: true

  alias PiFi.AirPlay.NowPlaying

  doctest PiFi.AirPlay.NowPlaying

  @artwork <<0xFF, 0xD8, 0xFF, 0xE0>> <> :binary.copy(<<0>>, 200)

  defp sent(fields) do
    %{
      "type" => "updateMRNowPlayingInfo",
      "params" => %{"mergePolicy" => "replace", "type" => "npi-text", "params" => fields}
    }
  end

  defp podcast do
    sent(%{
      "kMRMediaRemoteNowPlayingInfoAlbum" => "26 November 2025",
      "kMRMediaRemoteNowPlayingInfoArtist" => "Articles of Interest",
      "kMRMediaRemoteNowPlayingInfoArtworkData" => @artwork,
      "kMRMediaRemoteNowPlayingInfoArtworkDataHeight" => 600,
      "kMRMediaRemoteNowPlayingInfoArtworkDataWidth" => 600,
      "kMRMediaRemoteNowPlayingInfoArtworkIdentifier" => "fed0cb03554cac86",
      "kMRMediaRemoteNowPlayingInfoArtworkMIMEType" => "image/jpeg",
      "kMRMediaRemoteNowPlayingInfoDuration" => 3076.752,
      "kMRMediaRemoteNowPlayingInfoElapsedTime" => 49.955699958,
      "kMRMediaRemoteNowPlayingInfoMediaType" => "MRMediaRemoteMediaTypePodcast",
      "kMRMediaRemoteNowPlayingInfoTitle" => "Gear: Chapter 6 (S7 E7)"
    })
  end

  describe "a message from a telephone" do
    test "it reads the words a person sees" do
      assert {:ok, playing} = NowPlaying.read(podcast())

      assert playing.title == "Gear: Chapter 6 (S7 E7)"
      assert playing.artist == "Articles of Interest"
      assert playing.album == "26 November 2025"
    end

    # **The picture is in the message and not behind an address**, so nothing fetches
    # anything and a screen can draw it at once.
    test "it reads the artwork and its type" do
      assert {:ok, playing} = NowPlaying.read(podcast())

      assert playing.artwork == @artwork
      assert playing.artwork_type == "image/jpeg"
    end

    test "the line is the title and the artist" do
      assert {:ok, playing} = NowPlaying.read(podcast())

      assert NowPlaying.line(playing) == "Gear: Chapter 6 (S7 E7) · Articles of Interest"
    end
  end

  describe "a message that says nothing a person reads" do
    # **The first `npi-text` of a session carries an empty `params`.** A sender is
    # saying that it has not decided yet, and taking it for a track with no title would
    # wipe the title of the one that is playing.
    test "an empty message is ignored" do
      assert :ignore = NowPlaying.read(sent(%{}))
    end

    # A sender sends one of these whenever the elapsed time moves, which is once a
    # second. None of it reaches a person.
    test "a message of only the time is ignored" do
      assert :ignore =
               NowPlaying.read(sent(%{"kMRMediaRemoteNowPlayingInfoElapsedTime" => 12.3}))
    end

    test "a message of another kind is ignored" do
      assert :ignore = NowPlaying.read(%{"type" => "updateMRSupportedCommands", "params" => %{}})
    end

    test "a body that is not a message at all is ignored" do
      assert :ignore = NowPlaying.read("rubbish")
      assert :ignore = NowPlaying.read(%{})
    end

    # A field that a sender sent empty is one it has nothing for, and an empty title
    # would draw an empty line in front of a person.
    test "an empty title is no title" do
      assert :ignore = NowPlaying.read(sent(%{"kMRMediaRemoteNowPlayingInfoTitle" => ""}))
    end
  end

  describe "a message with only a picture" do
    # Artwork alone is worth taking: a sender sends the words and the picture in
    # separate messages when the picture takes longer to find.
    test "it is read even with no words in it" do
      assert {:ok, playing} =
               NowPlaying.read(sent(%{"kMRMediaRemoteNowPlayingInfoArtworkData" => @artwork}))

      assert playing.artwork == @artwork
      assert NowPlaying.line(playing) == nil
    end
  end
end
