defmodule MyHiFi.Screen.BarTest do
  use ExUnit.Case, async: true

  use Emerge.UI

  alias MyHiFi.Screen.Bar

  @width 100
  @height 10

  # The bar is a tree, so a test draws it and reads the pixels. The width of the part
  # that is full is what a person reads, so that is what these measure.
  defp pixels(part) do
    part
    |> Bar.render(
      width: @width,
      height: @height,
      track: color(:slate, 800),
      fill: color(:slate, 50)
    )
    |> EmergeSkia.render_to_pixels(otp_app: :my_hi_fi, width: @width, height: @height)
  end

  # The fill is near white and the track is near black, so a bright pixel is the fill.
  defp full(part) do
    Enum.count(for(<<red, green, blue, _a <- pixels(part)>>, do: red + green + blue), &(&1 > 500))
  end

  test "a fuller bar draws more" do
    assert full(0.9) > full(0.1)
  end

  # A track that just began must show that it began, so the part that is full never
  # falls to nothing.
  test "a bar of nothing still draws" do
    assert full(0.0) > 0
  end

  # The corners are round, so a bar that is full draws a little less than every pixel.
  test "a part above one draws no more than a bar that is full" do
    assert full(1.0) > full(0.9)
    assert full(2.0) == full(1.0)
  end
end
