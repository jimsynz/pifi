defmodule MyHiFi.Peripheral.PirateAudio.Screen do
  @moduledoc """
  The now playing view of the Pirate Audio, as an Emerge tree.

  This module holds the layout of a 240 by 240 screen and nothing else. It reads a
  `t:view/0`, which is what `MyHiFi.Peripheral.PirateAudio` builds from the events of
  the `:player` topic, and it gives a tree. It talks to no hardware and it holds no
  process, so a test draws it to a PNG and a person looks at the file.

  **The artwork fills the screen, and the words sit on top of it.** That is the whole
  design. The screen is square and small, and a person reads it from a chair, so one
  picture and two lines of text say more than a row of pills and a bar.

  ## How the words stay readable

  A colour that a picture gives cannot be trusted here, and this is the part that reads
  wrong at first. `MyHiFi.Artwork.Accent` gives the colour that a picture holds **most**
  of, and over that same picture it is therefore the colour most likely to disappear.
  The accent belongs on the slate of the web page and of the PiTFT, where it has a known
  background. It has none here.

  **A measurement of the picture cannot be trusted either.** The mean lightness of the
  place where the words go says nothing about the variance of it, and it is the variance
  that hides text: a bright window behind a dark coat takes away half the letters
  whatever single colour a caller picks.

  This draws a scrim instead, which is a band that fades from nothing to near black down
  the foot of the screen. It flattens the mean and the variance together, so light text
  on it reads over every picture and one code path serves them all. Emerge holds no
  shadow for text, so a shadow was never an answer here: `Emerge.UI.Border` gives
  `shadow/1` and `glow/2`, and those draw around the frame of an element and not around
  a letter.

  ## No progress bar

  A bar would mean a draw for each `MyHiFi.Event.Player.Progress` event, which is one
  each second, and each draw of this screen decodes a JPEG and scales it to cover 240 by
  240. This screen therefore draws when the track changes and not when it moves, and
  `MyHiFi.Peripheral.PirateAudio` ignores that event.
  """

  use Emerge.UI

  alias Emerge.UI.{Background, Border, Font}
  alias MyHiFi.Peripheral.BatteryIcon

  @width 240
  @height 240

  @typedoc """
  What the screen draws.

  `state` decides the words. `artwork_path` is the disk path of a thumbnail, or `nil`
  for a track that holds no picture, and the screen then draws a plain dark field.

  There is no `position_ms` and no `duration_ms`, because this screen draws no bar. See
  the moduledoc.
  """
  @type view :: %{
          state: :stopped | :buffering | :playing | :paused | :failed,
          title: String.t() | nil,
          subtitle: String.t() | nil,
          message: String.t() | nil,
          artwork_path: String.t() | nil,
          low_battery?: boolean(),
          battery_percent: 0..100 | nil
        }

  @doc "The size that this screen draws at."
  @spec size() :: {pos_integer(), pos_integer()}
  def size, do: {@width, @height}

  @doc "A view that shows nothing playing."
  @spec new() :: view()
  def new do
    %{
      state: :stopped,
      title: nil,
      subtitle: nil,
      message: nil,
      artwork_path: nil,
      low_battery?: false,
      battery_percent: nil
    }
  end

  @doc "Draw one view."
  @spec render(view()) :: Emerge.tree()
  def render(view) do
    el(
      [width(px(@width)), height(px(@height)), field(view)],
      column([width(fill()), height(fill())], [battery_row(view), spacer(), scrim(view)])
    )
  end

  @doc """
  The line that a person reads first.

  A track gives its title. A track that gives none, and a device that plays nothing,
  give the state in words instead, because a screen that shows an empty band tells a
  person nothing at all.

  **A cell that is nearly flat wins over all of that.** This device cannot turn its own
  power off, so the one thing that a person must do is charge it, and a track title
  beside that warning would only hide it.
  """
  @spec headline(view()) :: String.t()
  def headline(%{low_battery?: true}), do: "LOW BATTERY\nCHARGE NOW"
  def headline(%{title: title}) when is_binary(title), do: title
  def headline(%{state: :failed} = view), do: view.message || "Failed"
  def headline(%{state: :buffering}), do: "Buffering"
  def headline(%{state: :stopped}), do: "MyHiFi"
  def headline(_view), do: "Nothing is playing"

  # The artwork covers the screen, and a track with none gets the slate that the rest of
  # this firmware uses, so the words sit on a field that reads the same way.
  defp field(%{artwork_path: nil}), do: Background.color(color(:slate, 950))
  defp field(%{artwork_path: path}), do: Background.image({:path, path}, fit: :cover)

  # The picture takes every row that the words leave.
  defp spacer, do: el([width(fill()), height(fill())], none())

  # **A device on the mains draws no battery at all.** It holds no gauge, so it publishes
  # no charge, and a battery at 0 would be a lie. See `MyHiFi.Peripheral.Battery`.
  #
  # It sits at the top corner, over the artwork, because the foot of the screen belongs
  # to the words. The band behind it is what keeps it readable over a bright picture, in
  # the way that the scrim keeps the words readable.
  defp battery_row(%{battery_percent: nil}), do: none()

  defp battery_row(view) do
    row([width(fill()), padding_xy(10, 8)], [
      el([width(fill())], none()),
      el(
        [padding_xy(5, 4), Border.rounded(6), Background.color(color_rgba(0, 0, 0, 0.55))],
        BatteryIcon.render(view.battery_percent, view.low_battery?)
      )
    ])
  end

  # One flat band, and not a gradient that fades into the picture. **A gradient cannot
  # do that here**, and the reason is a rule of Emerge that a reader cannot guess.
  #
  # A measurement on 2026-09-01 drew a red to blue gradient in elements of four shapes
  # and read the pixels down the middle. **The ramp spans the diagonal of the element,
  # centred on it**, so a wide short band shows the middle of the ramp and never the
  # ends. A band of 240 by 85 has a diagonal of 254, so 33% of the ramp is visible and
  # the top of the band already stands at a third of the way along it.
  #
  # A fade from nothing at the top of such a band therefore needs a second colour of
  # 1.5 alpha, which cannot be written, and `Background.gradient/3` takes two colours
  # and no more. The first try drew a band that began at 0.34 alpha with a hard edge
  # and reached 0.6 where it wanted 0.88.
  #
  # 0.72 over white leaves 71 of 255. The title is `slate 50`, which is 248, so the two
  # stand about 9 to 1 apart whatever the picture holds.
  defp scrim(view) do
    column(
      [
        width(fill()),
        padding_xy(14, 12),
        spacing(3),
        Background.color(band(view))
      ],
      [title(view), subtitle(view)]
    )
  end

  # `paragraph/2` wraps and `el/2` with `text/1` does not. A podcast episode holds a long
  # title, and one that does not wrap goes past the edge of the glass.
  defp title(view) do
    paragraph([width(fill()), Font.size(19), Font.color(color(:slate, 50))], [
      text(headline(view))
    ])
  end

  # A warning reads as a warning by its colour before a person reads the words, and rose
  # is what `MyHiFi.Peripheral.PiTft.Screen` already gives a fault. The band holds more
  # of it than the scrim holds of black, because the words must win over the artwork.
  defp band(%{low_battery?: true}), do: color_rgba(136, 19, 55, 0.88)
  defp band(_view), do: color_rgba(0, 0, 0, 0.72)

  # The subtitle of a track says nothing beside a warning to charge the cell.
  defp subtitle(%{low_battery?: true}), do: none()
  defp subtitle(%{subtitle: nil}), do: none()

  defp subtitle(view) do
    paragraph([width(fill()), Font.size(14), Font.color(color(:slate, 300))], [
      text(view.subtitle)
    ])
  end
end
