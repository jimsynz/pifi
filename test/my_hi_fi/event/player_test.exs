defmodule MyHiFi.Event.PlayerTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Event.Player.Failed

  doctest MyHiFi.Event.Player.Failed

  describe "Failed.message/1" do
    test "an item that no read has filled says so, and it names itself" do
      assert Failed.message({:not_read_yet, "RNZ Concert"}) =~ "RNZ Concert"
      assert Failed.message({:not_read_yet, "RNZ Concert"}) =~ "no address"
    end

    test "a sound format that this device cannot play names the item" do
      assert Failed.message({:unsupported_format, "An episode"}) ==
               "This device cannot play the sound format of An episode."
    end

    # A person reads this one, and the identifier means nothing to them.
    test "an entry that is not a track says what plays" do
      assert Failed.message({:not_a_track, "0d0b7e2c"}) ==
               "That entry is not a track, and only a track plays."
    end

    test "a fault of the network names what the server answered" do
      assert Failed.message({:status, 404}) == "The server answered with the status 404."

      assert Failed.message({:cannot_read_playlist, "no such host"}) =~ "no such host"
    end

    # Each reason that a person meets earns a sentence, and this holds the rest until
    # one does. It must still give text, because a page draws what it gives.
    test "a reason with no sentence gives the reason as it stands" do
      assert Failed.message({:something_new, :here}) ==
               "The player stopped: {:something_new, :here}"
    end
  end
end
