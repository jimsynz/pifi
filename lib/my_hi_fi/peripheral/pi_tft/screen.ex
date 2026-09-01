defmodule MyHiFi.Peripheral.PiTft.Screen do
  @moduledoc """
  The now playing view of the PiTFT, as an Emerge tree.

  This module holds the layout of a 320 by 240 screen and nothing else. It reads a
  `t:view/0`, which is what `MyHiFi.Peripheral.PiTft` builds from the events of the
  `:player` topic, and it gives a tree. It talks to no hardware and it holds no
  process, so a test draws it to a PNG and a person looks at the file.

  The layout is deliberately plain. A person reads this screen from a chair, across
  a room, so the title takes the largest text that fits two lines.

  A browse view comes with `MyHiFi.DeviceUi`, which owns the list and the selected
  index. This module draws no list today.
  """

  use Emerge.UI

  alias Emerge.UI.{Background, Border, Font}

  @width 320
  @height 240

  @typedoc """
  What the screen draws.

  `state` decides the whole picture. `:stopped` shows the name of the device,
  because a person who sees nothing else needs to know that the device is awake.

  `artwork_path` is the disk path of a thumbnail image, or `nil` for no artwork.
  The path must be absolute and allowed by Emerge's runtime paths configuration.

  `accent` is the colour of that artwork, as red, green and blue, or `nil` for a
  picture that gives no colour. The bar of the progress and the pill of the status
  take it, and the text does not: a colour that a picture gives is held inside a band
  that reads well, and text is where a colour that misses that band stops a person
  from reading the screen. See `MyHiFi.Artwork.Accent`.
  """
  @type view :: %{
          state: :stopped | :buffering | :playing | :paused | :failed,
          title: String.t() | nil,
          subtitle: String.t() | nil,
          message: String.t() | nil,
          artwork_path: String.t() | nil,
          accent: {0..255, 0..255, 0..255} | nil,
          live?: boolean(),
          percent: 0..100,
          position_ms: non_neg_integer(),
          duration_ms: pos_integer() | nil
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
      accent: nil,
      live?: false,
      percent: 0,
      position_ms: 0,
      duration_ms: nil
    }
  end

  @doc "Draw one view."
  @spec render(view()) :: Emerge.tree()
  def render(view) do
    column(
      [
        width(px(@width)),
        height(px(@height)),
        padding(16),
        spacing(10),
        Background.color(color(:slate, 950))
      ],
      [status_row(view), body(view), progress(view)]
    )
  end

  @doc """
  What a person reads at the top of the screen.

  A live stream says so, because a duration cannot say it and a person wants to
  know that there is nothing to skip.
  """
  @spec status_text(view()) :: String.t()
  def status_text(%{state: :stopped}), do: "MyHiFi"
  def status_text(%{state: :failed}), do: "Failed"
  def status_text(%{state: :buffering, percent: percent}), do: "Buffering #{percent}%"
  def status_text(%{state: :paused}), do: "Paused"
  def status_text(%{live?: true}), do: "Live"
  def status_text(_view), do: "Playing"

  @doc """
  The time of a track, as minutes and seconds.

  An hour or more takes a third part, because a podcast episode runs that long and
  a person reading "97:12" has to do the arithmetic.
  """
  @spec clock(non_neg_integer()) :: String.t()
  def clock(milliseconds) do
    seconds = div(milliseconds, 1000)
    minutes = div(seconds, 60)

    case div(minutes, 60) do
      0 -> "#{minutes}:#{pad(rem(seconds, 60))}"
      hours -> "#{hours}:#{pad(rem(minutes, 60))}:#{pad(rem(seconds, 60))}"
    end
  end

  defp status_row(view) do
    row([width(fill()), spacing(8)], [
      el(
        [
          padding_xy(8, 3),
          Border.rounded(999),
          Background.color(status_colour(view)),
          Font.size(13),
          Font.color(color(:slate, 950))
        ],
        text(status_text(view))
      ),
      el(
        [width(fill()), Font.size(13), Font.color(color(:slate, 500)), align_right()],
        text(elapsed(view))
      )
    ])
  end

  # The body takes the space that the status row and the progress bar leave, so the
  # bar sits at the foot of the screen and does not follow a title of one line.
  # Artwork sits on the left, and the title and subtitle sit on the right.
  defp body(view) do
    row([width(fill()), height(fill()), spacing(10)], [
      artwork(view),
      column([width(fill()), height(fill()), spacing(6)], [title(view), subtitle(view)])
    ])
  end

  # The artwork is a square thumbnail, 120 pixels on each side. A track that holds
  # no artwork shows nothing in that place, and the text takes the full width.
  defp artwork(%{artwork_path: nil}), do: none()

  defp artwork(%{artwork_path: path}) do
    image(
      [width(px(120)), height(px(120)), Border.rounded(8), image_fit(:cover)],
      {:path, path}
    )
  end

  # `paragraph/2` wraps, and `el/2` with `text/1` does not. A title of a podcast
  # episode is long, and a title that does not wrap goes past the edge of the glass.
  defp title(%{title: nil} = view) do
    paragraph([width(fill()), Font.size(20), Font.color(color(:slate, 500))], [
      text(view.message || "Nothing is playing")
    ])
  end

  defp title(view) do
    paragraph([width(fill()), Font.size(28), Font.color(color(:slate, 50))], [text(view.title)])
  end

  defp subtitle(%{subtitle: nil}), do: none()

  defp subtitle(view) do
    paragraph([width(fill()), Font.size(17), Font.color(color(:slate, 400))], [
      text(view.subtitle)
    ])
  end

  defp progress(%{duration_ms: nil}), do: none()

  defp progress(view) do
    el(
      [width(fill()), height(px(6)), Border.rounded(3), Background.color(color(:slate, 800))],
      el(
        [
          width(px(played_width(view))),
          height(px(6)),
          Border.rounded(3),
          Background.color(accent(view, color(:emerald, 500)))
        ],
        none()
      )
    )
  end

  # `use Emerge.UI` brings its own `min/2` and `max/2`, which build layout
  # constraints and not numbers, so this names the `Kernel` ones.
  #
  # A bar of zero width draws nothing, and a track that just began still needs to
  # show that it began.
  defp played_width(view) do
    played = Kernel.min(view.position_ms, view.duration_ms)
    Kernel.max(round((@width - 32) * played / view.duration_ms), 2)
  end

  defp elapsed(%{state: :stopped}), do: ""
  defp elapsed(%{duration_ms: nil} = view), do: clock(view.position_ms)
  defp elapsed(view), do: "#{clock(view.position_ms)} / #{clock(view.duration_ms)}"

  # **The pill says which state the player is in, so a colour of the artwork takes the
  # place of one state alone.** Buffering is amber and a fault is rose on every track,
  # because a person reads those two by their colour before they read the word.
  defp status_colour(%{state: :failed}), do: color(:rose, 400)
  defp status_colour(%{state: :playing} = view), do: accent(view, color(:emerald, 400))
  defp status_colour(%{state: :buffering}), do: color(:amber, 400)
  defp status_colour(_view), do: color(:slate, 500)

  # A picture of greys gives no colour, and a track with no artwork gives none either,
  # so each place that draws one names what it draws instead.
  defp accent(%{accent: {red, green, blue}}, _instead), do: color_rgb(red, green, blue)
  defp accent(_view, instead), do: instead

  defp pad(seconds), do: String.pad_leading(to_string(seconds), 2, "0")
end
