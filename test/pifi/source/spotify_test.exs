defmodule PiFi.Source.SpotifyTest do
  use PiFi.DataCase, async: false

  doctest PiFi.Source.Spotify

  alias PiFi.Playback.Item
  alias PiFi.Settings
  alias PiFi.Source

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
  describe "what it cannot do" do
    test "it has no branches" do
      assert {:error, Source.Spotify} = Source.Spotify.roots()
    end

    test "it resolves nothing" do
      assert {:error, Source.Spotify} = Source.Spotify.resolve(%Item{})
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
