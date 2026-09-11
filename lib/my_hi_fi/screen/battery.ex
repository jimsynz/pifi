defmodule MyHiFi.Screen.Battery do
  @moduledoc """
  A battery, drawn for a screen that Emerge renders.

  `MyHiFi.Peripheral.PiTft.Screen` and `MyHiFi.Peripheral.PirateAudio.Screen` both draw
  one, and the shape of a battery belongs to neither of them. **This is a component and
  not a layout**: each screen still decides where the battery sits and how large it is,
  which is the rule that `MyHiFi.Peripheral` names.

  ## Why it is drawn and not an image

  Emerge draws an SVG with `Emerge.UI.svg/2`, which takes a source that it must read from
  the disk, and a runtime path of this firmware is a thumbnail of the cache and nothing
  else. See `MyHiFi.Screen.Renderer.assets/0`. Three rectangles need no
  file, no allowlist and no decode, and they stay sharp at 11 pixels tall where a scaled
  image does not.

  Heroicons has `battery-0`, `battery-50` and `battery-100` and nothing between them,
  so the web page cannot use those either and draws its own.

  ## The fill says the charge, and the colour says the warning

  A person reads the length of the bar for the charge, and they read rose for a cell that
  needs charging before they read anything at all. The two are separate, because a cell
  at 15 percent and a cell at 15 percent with a higher threshold look the same and mean
  different things.
  """

  use Emerge.UI

  alias Emerge.UI.{Background, Border}

  @doc """
  Draw one battery.

  `percent` is 0 to 100 and `low?` says whether a person must charge it now.

  ## Options

  - `:height` - the height of the body, in pixels. 11 by default.
  - `:width` - the width of the body, in pixels. 22 by default.

  **A bar of no width draws nothing**, and a cell at 1 percent is not a cell at 0, so the
  fill never falls below one pixel while any charge is left.
  """
  @spec render(0..100, boolean(), keyword()) :: Emerge.tree()
  def render(percent, low?, opts \\ []) do
    height = Keyword.get(opts, :height, 11)
    width = Keyword.get(opts, :width, 22)
    colour = colour(low?)

    row([spacing(1), center_y()], [body(percent, width, height, colour), nub(height, colour)])
  end

  defp body(percent, width, height, colour) do
    el(
      [
        width(px(width)),
        height(px(height)),
        padding(2),
        Border.width(1),
        Border.color(colour),
        Border.rounded(3)
      ],
      el(
        [width(px(fill_width(percent, width))), height(fill()), Background.color(colour)],
        none()
      )
    )
  end

  # The terminal of a battery, which is what makes the shape read as one at this size.
  #
  # `use Emerge.UI` brings its own `min/2` and `max/2`, and they build layout constraints
  # and not numbers, so this and `fill_width/2` both name the `Kernel` ones.
  defp nub(height, colour) do
    el(
      [
        width(px(2)),
        height(px(Kernel.max(round(height / 3), 3))),
        Background.color(colour),
        Border.rounded(1)
      ],
      none()
    )
  end

  # The body draws a border of 1 and a padding of 2 on each side, so 6 pixels of it are
  # not the bar.
  defp fill_width(percent, width) do
    inside = width - 6

    percent
    |> Kernel./(100)
    |> Kernel.*(inside)
    |> round()
    |> Kernel.max(1)
    |> Kernel.min(inside)
  end

  defp colour(true), do: color(:rose, 400)
  defp colour(false), do: color(:slate, 300)
end
