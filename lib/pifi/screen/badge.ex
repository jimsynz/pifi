defmodule PiFi.Screen.Badge do
  @moduledoc """
  A word or a mark in a hard panel, drawn for a screen that Emerge renders.

  **Both screens draw the state of the player in one of these**, and the fill is the
  colour of that state, so a person reads the block of colour before they read the
  word. See `PiFi.Screen.Style.state_colour/1`.

  **The panel is flat, square and bordered, and it is not a translucent band.** An
  earlier version drew black at 55 percent, which let a bright cover through and left
  the mark hard to read over the worst of them. `PiFi.Screen.Style.panel_over_art/0`
  is near opaque, the border of ink cuts the panel away from a picture under it, and
  the offset shadow lifts it off that picture. That is the style of the product, and
  over artwork it is also what makes the words readable. See `PiFi.Screen.Style`.

  **The battery and the network draw no panel.** A row of three boxes reads as clutter
  on a glass of 240 pixels, and the two marks of the hardware are shapes and not words:
  a person reads a bar and three rising bars at a glance where they must read a word
  letter by letter. See `PiFi.Screen`.
  """

  use Emerge.UI

  alias Emerge.UI.Background
  alias PiFi.Screen.Style

  @doc """
  Put one mark in a panel.

  ## Options

  - `:padding` - the space around the mark, as `{across, down}` in pixels. `{5, 3}` by
    default.
  - `:fill` - the colour of the panel. `PiFi.Screen.Style.panel_over_art/0` by default.
    **A chip that says the state of the player gives the colour of that state**, and
    the words in it then take `PiFi.Screen.Style.ground/0`, because a block of colour
    carries dark words. See `PiFi.Screen.Style.state_colour/1`.
  """
  @spec render(Emerge.tree(), keyword()) :: Emerge.tree()
  def render(mark, options \\ []) do
    {across, down} = Keyword.get(options, :padding, {5, 3})
    fill = Keyword.get(options, :fill, Style.panel_over_art())

    el(
      [padding_xy(across, down), Background.color(fill)] ++
        Style.edge() ++ [Style.offset(size: :sm)],
      mark
    )
  end
end
