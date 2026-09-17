defmodule PiFi.Hardware.ConfigTxtTest do
  use ExUnit.Case, async: true

  alias PiFi.Hardware.ConfigTxt

  @stock """
  arm_64bit=1
  dtparam=spi=on
  dtoverlay=dwc2,dr_mode=host
  """

  @lines ["dtoverlay=hifiberry-dac", "gpio=25=op,dh"]

  describe "putting a profile into the text" do
    test "the lines go in a block at the end" do
      written = ConfigTxt.put(@stock, @lines)

      assert written =~ "# --- PiFi hardware profile: begin ---"
      assert written =~ "dtoverlay=hifiberry-dac"
      assert written =~ "gpio=25=op,dh"
      assert written =~ "# --- PiFi hardware profile: end ---"
    end

    # Everything outside the two marks belongs to the Nerves system, so a later version
    # of it changes `config.txt` freely.
    test "it keeps every line that the system wrote" do
      written = ConfigTxt.put(@stock, @lines)

      for line <- ["arm_64bit=1", "dtparam=spi=on", "dtoverlay=dwc2,dr_mode=host"] do
        assert written =~ line
      end
    end

    test "a second profile takes the place of the first, and makes no second block" do
      written =
        @stock
        |> ConfigTxt.put(@lines)
        |> ConfigTxt.put(["dtoverlay=something-else"])

      assert ConfigTxt.lines(written) == ["dtoverlay=something-else"]
      refute written =~ "hifiberry"
      assert length(String.split(written, "profile: begin")) == 2
    end

    test "a profile of no lines takes the block away" do
      written =
        @stock
        |> ConfigTxt.put(@lines)
        |> ConfigTxt.put([])

      assert ConfigTxt.lines(written) == []
      refute written =~ "PiFi hardware profile"
      assert written =~ "dtparam=spi=on"
    end

    test "writing the same profile again changes nothing" do
      once = ConfigTxt.put(@stock, @lines)

      assert ConfigTxt.put(once, @lines) == once
    end

    test "the text ends with one newline, whatever it began with" do
      for stock <- [@stock, String.trim_trailing(@stock), @stock <> "\n\n\n"] do
        written = ConfigTxt.put(stock, @lines)

        assert String.ends_with?(written, "---\n")
        refute String.ends_with?(written, "\n\n")
      end
    end
  end

  describe "reading the lines that the text holds" do
    test "a text with no block holds none" do
      assert ConfigTxt.lines(@stock) == []
    end

    test "it gives the lines that a write put there" do
      assert @stock |> ConfigTxt.put(@lines) |> ConfigTxt.lines() == @lines
    end

    # A file that a person edited by hand, or a write that stopped in the middle.
    test "a block with no end holds nothing, and a write repairs the text" do
      broken = @stock <> "# --- PiFi hardware profile: begin ---\ndtoverlay=half-written\n"

      assert ConfigTxt.lines(broken) == ["dtoverlay=half-written"]

      written = ConfigTxt.put(broken, @lines)

      assert ConfigTxt.lines(written) == @lines
      refute written =~ "half-written"
    end
  end

  # `PiFi.Hardware` reads this at each boot. It compares the text of the file and
  # never the hardware that answers, so a restart that repeats has no way to begin.
  describe "whether the text already holds a profile" do
    test "it holds the lines that a write put there" do
      assert @stock |> ConfigTxt.put(@lines) |> ConfigTxt.carries?(@lines)
    end

    test "a text that an upgrade wrote again holds none of them" do
      refute ConfigTxt.carries?(@stock, @lines)
    end

    test "another profile is not this one" do
      written = ConfigTxt.put(@stock, ["dtoverlay=something-else"])

      refute ConfigTxt.carries?(written, @lines)
    end

    test "a text with no block holds the profile of no lines" do
      assert ConfigTxt.carries?(@stock, [])
    end
  end
end
