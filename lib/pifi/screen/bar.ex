defmodule PiFi.Screen.Bar do
  @moduledoc """
  A bar that is part full, drawn for a screen that Emerge renders.

  The place of a track and the level of the volume are both this shape, and both
  screens draw both, so four copies of it stood in two modules. See `PiFi.Screen`.

  **A bar that is empty draws nothing, and that is wrong for a track that just began.**
  The fill therefore never falls below two pixels. A caller that wants no bar at all
  for an empty value tests the value itself and draws `Emerge.UI.none/0`.

  **The caller gives the width in pixels.** Emerge takes a share of the parent for the
  width of an element, and the fill of a bar is a share of the bar and not of the row
  around it, so the caller works the number out from the width of its own layout.
  """

  use Emerge.UI

  alias Emerge.UI.{Background, Border}

  @least 2

  @doc """
  Draw one bar.

  `part` is how full it is, from 0.0 to 1.0. A value outside that reads as the nearer
  end of it.

  ## Options

  - `:width` - how wide the whole bar is, in pixels. It is required.
  - `:height` - how tall it is, in pixels. It is required.
  - `:fill` - the colour of the part that is full. It is required.
  - `:track` - the colour of the rest of it. It is required.
  - `:radius` - how round the corners are, in pixels. Half of the height by default.
  """
  @spec render(float(), keyword()) :: Emerge.tree()
  def render(part, options) do
    width = Keyword.fetch!(options, :width)
    height = Keyword.fetch!(options, :height)
    radius = Keyword.get(options, :radius, round(height / 2))

    el(
      [
        width(fill()),
        height(px(height)),
        Border.rounded(radius),
        Background.color(Keyword.fetch!(options, :track))
      ],
      el(
        [
          width(px(full_width(part, width))),
          height(px(height)),
          Border.rounded(radius),
          Background.color(Keyword.fetch!(options, :fill))
        ],
        none()
      )
    )
  end

  # `use Emerge.UI` brings its own `min/2` and `max/2`, which build layout constraints
  # and not numbers, so this names the `Kernel` ones.
  defp full_width(part, width) do
    part
    |> Kernel.*(width)
    |> round()
    |> Kernel.max(@least)
    |> Kernel.min(width)
  end
end
