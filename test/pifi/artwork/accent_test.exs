defmodule PiFi.Artwork.AccentTest do
  use ExUnit.Case, async: true

  alias PiFi.Artwork.Accent

  # A grid of pixels, in the order that `vipsthumbnail` writes raw bytes.
  defp grid(colours) do
    for {red, green, blue} <- colours, into: <<>>, do: <<red, green, blue>>
  end

  defp of(colours), do: colours |> grid() |> Accent.from_pixels()

  defp many(colour, count), do: List.duplicate(colour, count)

  describe "from_pixels/1" do
    test "a picture of one colour gives that hue" do
      red = of(many({200, 30, 40}, 64))
      blue = of(many({30, 60, 200}, 64))

      # OKLab holds red near 30 degrees and blue near 265.
      assert_in_delta red.hue, 30, 12
      assert_in_delta blue.hue, 265, 12
    end

    test "a picture of greys gives no colour at all" do
      assert of(many({120, 120, 120}, 64)) == nil
      assert of(many({20, 20, 20}, 64)) == nil
      assert of(many({240, 240, 240}, 64)) == nil
    end

    test "a picture of black and white gives no colour" do
      assert of(many({0, 0, 0}, 32) ++ many({255, 255, 255}, 32)) == nil
    end

    # A cover holds a great deal of dark and light, and a little colour. The weight is
    # the square of the chroma, so the little colour is what a person sees and what
    # this answers.
    test "a strong colour of a few pixels beats a weak colour of many" do
      accent = of(many({130, 128, 126}, 984) ++ many({0, 110, 200}, 40))

      assert_in_delta accent.hue, 250, 25
    end

    # **The most that a picture holds is what a person sees in it.** A cover of a dark
    # room with one red shirt holds a red that no bucket carries far, and that red is
    # still the colour of the cover.
    test "a picture that holds a little colour gives that colour" do
      accent = of(many({130, 128, 126}, 1020) ++ many({0, 110, 200}, 4))

      assert_in_delta accent.hue, 250, 25
    end

    # The chroma of the winning bucket says whether a picture holds colour, and the
    # weight of it does not, so a grid of any size answers the same way.
    test "the size of the grid does not change the answer" do
      small = of(many({130, 128, 126}, 60) ++ many({0, 110, 200}, 4))
      large = of(many({130, 128, 126}, 984) ++ many({0, 110, 200}, 40))

      assert_in_delta small.hue, large.hue, 1
    end

    test "the answer holds the band that reads on a dark screen" do
      for colour <- [{255, 0, 0}, {0, 40, 0}, {90, 0, 120}, {255, 240, 0}] do
        accent = of(many(colour, 64))

        assert accent.lightness >= 0.72 and accent.lightness <= 0.84
        assert accent.chroma >= 0.08 and accent.chroma <= 0.19
        assert accent.hue >= 0 and accent.hue < 360
      end
    end

    test "a grid that holds no whole pixels gives nothing" do
      assert Accent.from_pixels(<<1, 2, 3, 4>>) == nil
      assert Accent.from_pixels("") == nil
      assert Accent.from_pixels(nil) == nil
    end

    # A thumbnail of one band gives one byte for each pixel, and this is what
    # `--colourspace srgb` in `PiFi.Artwork.Thumbnail` stops.
    test "a grid of one band reads as greys and gives nothing" do
      assert of(many({120, 120, 120}, 64)) == nil
    end
  end

  describe "from_ppm/1" do
    defp ppm(magic, colours) do
      count = length(colours)
      magic <> "\n# written by vipsthumbnail\n#{count} 1\n255\n" <> grid(colours)
    end

    test "it reads the grid of three bands that vipsthumbnail writes" do
      accent = Accent.from_ppm(ppm("P6", many({200, 30, 40}, 1024)))

      assert_in_delta accent.hue, 30, 12
    end

    # A thumbnail of one band writes `P5`, and its bytes hold one grey for each pixel.
    # A reader that took them for three bands would answer a colour that no person can
    # see in the picture.
    test "a grid of one band gives no colour" do
      assert Accent.from_ppm(ppm("P5", many({200, 30, 40}, 1024))) == nil
    end

    test "anything that is not a PPM gives no colour" do
      assert Accent.from_ppm("not a picture") == nil
      assert Accent.from_ppm("") == nil
    end
  end

  describe "to_rgb/1" do
    test "it gives back the hue that it was given" do
      for colour <- [{200, 30, 40}, {30, 60, 200}, {40, 180, 90}] do
        accent = of(many(colour, 64))
        {red, green, blue} = Accent.to_rgb(accent)
        again = of(many({red, green, blue}, 64))

        assert_in_delta again.hue, accent.hue, 3
      end
    end

    test "each part is one byte" do
      accent = of(many({255, 0, 0}, 64))
      {red, green, blue} = Accent.to_rgb(accent)

      for part <- [red, green, blue] do
        assert part in 0..255
      end
    end
  end

  describe "to_css/1" do
    test "it names the colour as a page does" do
      accent = of(many({200, 30, 40}, 64))

      assert Accent.to_css(accent) =~ ~r/\Aoklch\(0\.\d+ 0\.\d+ \d+(\.\d+)?\)\z/
    end
  end
end
