defmodule MyHiFi.Screen.BadgeTest do
  use ExUnit.Case, async: true

  use Emerge.UI

  alias MyHiFi.Screen.Badge
  alias MyHiFi.Test.Drawing

  @width 60
  @height 30

  defp pixels(tree) do
    tree
    |> Drawing.pixels(@width, @height)
  end

  defp mark do
    el([width(px(10)), height(px(10)), Background.color(color(:slate, 50))], none())
  end

  defp dark(pixels) do
    Enum.count(for(<<red, green, blue, alpha <- pixels>>, do: {red + green + blue, alpha}), fn
      {light, alpha} -> alpha > 0 and light < 200
    end)
  end

  # The band is what makes a mark readable over a bright picture, so the test that
  # matters is that the badge draws dark pixels where the mark alone draws none.
  test "it puts a dark band under the mark" do
    assert dark(pixels(Badge.render(mark()))) > dark(pixels(mark()))
  end

  test "a larger padding draws a larger band" do
    small = dark(pixels(Badge.render(mark(), padding: {2, 2})))
    large = dark(pixels(Badge.render(mark(), padding: {8, 8})))

    assert large > small
  end
end
