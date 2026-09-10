defmodule MyHiFi.Screen.RowTest do
  use ExUnit.Case, async: true

  use Emerge.UI

  alias MyHiFi.Screen.Row

  @width 100
  @height 10

  defp pixels(tree) do
    EmergeSkia.render_to_pixels(tree, otp_app: :my_hi_fi, width: @width, height: @height)
  end

  defp block do
    el([width(px(10)), height(px(10)), Background.color(color(:slate, 50))], none())
  end

  # The row is a tree, so a test draws it and reads which columns hold a block.
  defp columns(tree) do
    bytes = pixels(tree)

    for column <- 0..(@width - 1),
        <<red, _green, _blue, _alpha>> = binary_part(bytes, column * 4, 4),
        red > 200,
        do: column
  end

  test "it puts the first thing at one end and the second at the other" do
    columns = columns(Row.ends([block()], [block()]))

    assert Enum.min(columns) == 0
    assert Enum.max(columns) == @width - 1
  end

  test "two things at one end sit beside each other" do
    columns = columns(Row.ends([block()], [block(), block()]))

    assert Enum.max(columns) - Enum.min(columns) == @width - 1
    assert length(columns) == 30
  end

  test "a padding moves each end in from the edge" do
    columns = columns(Row.ends([block()], [block()], padding: {6, 0}))

    assert Enum.min(columns) == 6
    assert Enum.max(columns) == @width - 7
  end

  test "a spacing holds two things at one end apart" do
    apart = columns(Row.ends([block()], [block(), block()], spacing: 4))

    assert length(apart) == 30
    refute apart == columns(Row.ends([block()], [block(), block()]))
  end
end
