defmodule MyHiFi.Screen.Badge do
  @moduledoc """
  A mark on a dark band, drawn for a screen that Emerge renders.

  A screen that draws artwork over the whole glass puts the state of the hardware on
  top of it, and a bright picture takes a thin mark away. The band under the mark is
  what keeps it readable, and it is the small form of the scrim that
  `MyHiFi.Peripheral.PirateAudio.Screen` draws under the words.

  **The band is flat and not a gradient**, for the reason that the scrim gives: no
  measurement of a picture says whether a mark over it reads, because it is the
  variance of the pixels that hides one and a mean says nothing about variance.

  A screen that holds a dark field of its own needs no band at all, and it draws the
  mark and not this. See `MyHiFi.Screen`.
  """

  use Emerge.UI

  alias Emerge.UI.{Background, Border}

  @doc """
  Put one mark on a band.

  ## Options

  - `:padding` - the space around the mark, as `{across, down}` in pixels. `{5, 4}` by
    default.
  - `:radius` - how round the corners are, in pixels. 6 by default.
  """
  @spec render(Emerge.tree(), keyword()) :: Emerge.tree()
  def render(mark, options \\ []) do
    {across, down} = Keyword.get(options, :padding, {5, 4})

    el(
      [
        padding_xy(across, down),
        Border.rounded(Keyword.get(options, :radius, 6)),
        Background.color(color_rgba(0, 0, 0, 0.55))
      ],
      mark
    )
  end
end
