defmodule PiFi.Screen.Style do
  @moduledoc """
  The colours, the type and the edges that every screen of this device draws with.

  **The screens follow the style of the PiFi website**, which is neubrutalist: flat
  colour, a hard border, an offset shadow with no blur, and no round corner anywhere.
  See <https://neubrutalism.com/#anatomy> for the rules of it. A part of
  `PiFi.Screen` takes its values from here, and it names no colour of its own, so the
  two screens and the seven parts cannot drift apart.

  ## The dark ground, and why

  The website holds two schemes, and this is the dark one: the ground is near black,
  the ink is near white, and **the offset shadow is cyan, because a black shadow on a
  black ground is nothing at all**. `sass/main.scss` of the website makes the same
  choice for the same reason.

  A device screen takes the dark scheme and not the light one. A person reads this
  screen beside a bed and in a room at night, and a panel of paper white would light
  the room. Album artwork also reads against a dark ground and washes out against a
  light one.

  ## The sizes are smaller than the website, and they must be

  The website sets a border of 3 pixels and offsets of 3, 5 and 8 on a page that is
  1088 pixels wide. This screen is 240. The same numbers on this glass would give a
  border that is 8 times heavier than the one that a person reads in a browser, so
  the border here is 2 pixels and the offsets are 2 and 3. The **look** carries over,
  and the measurements do not.

  ## The typeface

  Archivo Black is the display face of the mark and of the website, and
  `PiFi.Screen.Renderer` loads it into each renderer under the name that
  `display_face/0` gives. A screen names it for a heading and leaves the body text in
  the face that Skia uses, because a body of 13 pixels in a black weight is a body
  that no person can read.

  `display/1` gives the face and the size together, and a heading that named only the
  size would draw in the wrong face.
  """

  import Emerge.UI.Color, only: [color_rgb: 3, color_rgba: 4]

  alias Emerge.UI.{Border, Font}

  @doc "The ground that a screen fills, when no picture fills it."
  @spec ground() :: tuple()
  def ground, do: color_rgb(0x13, 0x13, 0x13)

  @doc "The colour of the text, of every border and of a black shape of the mark."
  @spec ink() :: tuple()
  def ink, do: color_rgb(0xF7, 0xF2, 0xE7)

  @doc "The fill of a panel that sits on the ground."
  @spec panel() :: tuple()
  def panel, do: color_rgb(0x1D, 0x1D, 0x1D)

  @doc """
  The fill of a panel that sits over artwork.

  A panel over a picture must hide the picture, and `panel/0` over a bright cover
  leaves the cover showing at the edges of the letters. This is the same colour and
  it is not quite opaque, so the picture reads as a texture under the panel and never
  as a thing that takes the words away.
  """
  @spec panel_over_art() :: tuple()
  def panel_over_art, do: color_rgba(0x1D, 0x1D, 0x1D, 0.94)

  @doc "The first colour of the mark. It marks the thing that a person acts on."
  @spec cyan() :: tuple()
  def cyan, do: color_rgb(0x2F, 0xC6, 0xE8)

  @doc "The second colour of the mark. It marks the level of the sound."
  @spec amber() :: tuple()
  def amber, do: color_rgb(0xFF, 0xB0, 0x20)

  @doc "The colour of a fault and of a cell that is nearly flat."
  @spec coral() :: tuple()
  def coral, do: color_rgb(0xFF, 0x6B, 0x6B)

  @doc "The colour of a thing that is well. A charged cell takes it."
  @spec green() :: tuple()
  def green, do: color_rgb(0x88, 0xD4, 0x98)

  @doc "The colour of a thing that waits. Buffering takes it."
  @spec lavender() :: tuple()
  def lavender, do: color_rgb(0xB8, 0xA9, 0xFA)

  @doc "The colour of a warning that is not a fault."
  @spec yellow() :: tuple()
  def yellow, do: color_rgb(0xFF, 0xD2, 0x3F)

  @doc "The dim ink of a subtitle and of a time."
  @spec ink_dim() :: tuple()
  def ink_dim, do: color_rgb(0x9A, 0x96, 0x8D)

  @doc """
  The colour that a chip takes for one state of the player.

  **Each state holds one colour, and it never moves.** A person reads the block of
  colour before they read the word, so a colour that changed with the track would
  mean one thing on one track and another thing on the next.

      iex> PiFi.Screen.Style.state_colour(:failed) == PiFi.Screen.Style.coral()
      true
  """
  @spec state_colour(atom()) :: tuple()
  def state_colour(:failed), do: coral()
  def state_colour(:playing), do: green()
  def state_colour(:buffering), do: lavender()
  def state_colour(_state), do: ink_dim()

  @doc """
  The name that `PiFi.Screen.Renderer` registers the display face under.

  A screen gives it to `Emerge.UI.Font.family/1` through `display/1`.
  """
  @spec display_face() :: String.t()
  def display_face, do: "archivo-black"

  @doc "The face and the size of a heading, as attributes."
  @spec display(pos_integer()) :: [tuple()]
  def display(size), do: [Font.family(display_face()), Font.size(size)]

  @doc """
  The hard border of a panel, a chip or a bar.

  `:colour` names it, and `ink/0` is the one that almost everything takes. `:width`
  is 2 pixels by default, which is the border of the website at the size of this
  glass.
  """
  @spec edge(keyword()) :: [tuple()]
  def edge(options \\ []) do
    [
      Border.width(Keyword.get(options, :width, 2)),
      Border.color(Keyword.get(options, :colour, ink())),
      Border.rounded(0)
    ]
  end

  @doc """
  The offset shadow, which is the mark of this style.

  **The blur is 0 and it must stay 0.** A blurred shadow is the thing that
  neubrutalism is a reaction to, and Emerge blurs by 10 pixels when a caller says
  nothing.

  `:size` is `:sm` for a chip and `:md` for a panel. The website holds a third size
  for a hero, and this glass has no part that large.

  `:colour` is cyan by default, because the ground is near black and a black shadow
  on it is nothing at all.
  """
  @spec offset(keyword()) :: tuple()
  def offset(options \\ []) do
    pixels = pixels(Keyword.get(options, :size, :md))

    Border.shadow(
      offset: {pixels, pixels},
      blur: 0,
      color: Keyword.get(options, :colour, cyan())
    )
  end

  defp pixels(:sm), do: 2
  defp pixels(:md), do: 3
end
