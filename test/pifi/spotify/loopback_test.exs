defmodule PiFi.Spotify.LoopbackTest do
  use ExUnit.Case, async: true

  doctest PiFi.Spotify.Loopback

  alias PiFi.Spotify.Loopback

  # **The two halves of a loopback are crossed**, and naming the same device on both
  # sides is the mistake that costs an afternoon: it opens, it reads nothing, and it
  # says nothing about why.
  test "the two halves are different devices of one card" do
    refute Loopback.playback_device() == Loopback.capture_device()
    assert Loopback.playback_device() =~ "Loopback"
    assert Loopback.capture_device() =~ "Loopback"
  end

  # **A laptop is not a board**, and everything above this runs its tests on one. It
  # may have no `modprobe`, or have one and not be allowed to use it, and neither is a
  # reason to stop a test suite.
  test "a machine that cannot load the module says so rather than raising" do
    assert match?(:ok, Loopback.ensure_loaded()) or
             match?({:error, _reason}, Loopback.ensure_loaded())
  end

  test "whether the card is there is a question a machine with no ALSA can answer" do
    assert is_boolean(Loopback.loaded?())
  end
end
