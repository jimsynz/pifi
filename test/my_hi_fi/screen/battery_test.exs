defmodule MyHiFi.Screen.BatteryTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Screen.Battery

  # The icon is a tree, so a test draws it and reads the pixels. A bar that a caller
  # cannot see is the failure that matters, and the width of it is what says the charge.
  defp pixels(percent, low?, opts \\ []) do
    Battery.render(percent, low?, opts)
    |> EmergeSkia.render_to_pixels(otp_app: :my_hi_fi, width: 40, height: 20)
  end

  # The count of every lit pixel, and not the widest row. The border is the widest row
  # whatever the charge, so a measurement of that says nothing about the bar.
  defp lit(pixels) do
    Enum.count(for(<<red, green, blue, _a <- pixels>>, do: red + green + blue), &(&1 > 60))
  end

  test "it draws at the size that a caller asks for" do
    assert byte_size(pixels(50, false)) == 40 * 20 * 4
  end

  test "a fuller cell draws a longer bar" do
    thin = lit(pixels(10, false))
    fat = lit(pixels(100, false))

    assert fat > thin
  end

  # A cell with any charge left is not a cell at 0, so the bar never falls to nothing.
  test "a cell that is nearly flat still draws a bar" do
    assert lit(pixels(1, false)) > 0
  end

  test "a cell that is low draws in another colour" do
    steady = pixels(15, false)
    low = pixels(15, true)

    refute steady == low
  end

  test "a larger icon draws more" do
    small = lit(pixels(100, false, height: 9, width: 16))
    large = lit(pixels(100, false, height: 14, width: 30))

    assert large > small
  end
end
