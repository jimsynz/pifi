defmodule MyHiFi.Peripheral.ClockTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Peripheral.Clock

  doctest MyHiFi.Peripheral.Clock

  describe "text/1" do
    test "gives minutes and seconds under an hour" do
      assert Clock.text(0) == "0:00"
      assert Clock.text(9_000) == "0:09"
      assert Clock.text(69_000) == "1:09"
      assert Clock.text(3_599_000) == "59:59"
    end

    test "gives hours as well, because an episode runs that long" do
      assert Clock.text(3_600_000) == "1:00:00"
      assert Clock.text(5_832_000) == "1:37:12"
    end
  end
end
