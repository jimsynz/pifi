defmodule PiFi.Source.SpotifyTest do
  use PiFi.DataCase, async: false

  doctest PiFi.Source.Spotify

  alias PiFi.Playback.Item
  alias PiFi.Settings
  alias PiFi.Source
  alias PiFi.Spotify.Loopback

  setup do
    on_exit(fn ->
      case Settings.fetch(Source.enabled_key(Source.Spotify)) do
        {:ok, setting} -> Settings.delete!(setting)
        {:error, _reason} -> :ok
      end
    end)

    :ok
  end

  # **It receives audio rather than offering it**, so the two callbacks that a tree
  # needs answer that they cannot, in the way that `Enumerable` does. A caller reads
  # that and says something useful. See `t:PiFi.Source.unsupported/0`.
  # **A cast is shaped like a radio station**: the item is the input and the song
  # playing arrives beside it. One row, not one for each track — an SD card has a
  # finite number of writes and a cast track is in no catalogue.
  describe "the item that stands for the input" do
    test "there is one, and asking twice gives the same one" do
      first = Source.Spotify.item()
      second = Source.Spotify.item()

      assert first.id == second.id
      assert first.source == "spotify"
    end

    test "it is live, because a telephone decides when it ends" do
      assert %{live?: true, kind: :track} = Source.Spotify.item()
    end
  end

  describe "what it cannot do" do
    test "it has no branches" do
      assert {:error, Source.Spotify} = Source.Spotify.roots()
    end

    # **It resolves now, and it did not used to.** A cast went straight to the sound
    # card, so there was no audio here to give. librespot plays into an ALSA loopback
    # now and the player reads the other half, so there is somewhere to point at.
    test "it resolves the loopback that librespot plays into" do
      assert {:ok, playable} = Source.Spotify.resolve(%Item{})
      assert playable.transport == :capture
      assert playable.format == :raw
      assert playable.live?
      assert playable.uri == Loopback.capture_device()
    end

    # A telephone decides when a cast stops, so there is no length to count against.
    test "a cast has no end that this device knows" do
      assert {:ok, %{live?: true, position_ms: 0}} = Source.Spotify.resolve(%Item{})
    end

    test "it has no kind of item, and offers nothing beyond the tree" do
      assert [] = Source.Spotify.kinds()
      assert [] = Source.Spotify.capabilities()
    end
  end

  # It opens a port, and the licence question is the person's to answer. Every other
  # source comes into use as soon as it is ready.
  describe "whether a person has turned it on" do
    test "a device that no person changed holds it off" do
      refute Source.enabled?(Source.Spotify)
      refute Source.Spotify in Source.enabled()
    end

    test "a person turns it on and it joins the sources in use" do
      Source.enable(Source.Spotify, true)

      assert Source.enabled?(Source.Spotify)
      assert Source.Spotify in Source.enabled()
    end
  end

  # A person deciding whether to take the risk reads it where they press the control.
  describe "what it tells a person" do
    test "the licence question is one of the paragraphs, and it is marked a warning" do
      assert Enum.any?(Source.description(Source.Spotify), fn
               {:warning, text} -> text =~ "against their terms"
               _text -> false
             end)
    end

    test "it says that a Premium account is needed" do
      assert Enum.any?(Source.description(Source.Spotify), fn
               {:warning, text} -> text =~ "Premium"
               text -> text =~ "Premium"
             end)
    end
  end
end
