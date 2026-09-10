defmodule MyHiFi.Peripheral.PiTft.Screen do
  @moduledoc """
  The now playing view of the PiTFT, as an Emerge tree.

  This module owns the layout of a 320 by 240 screen and nothing else. It reads a
  `t:view/0`, which is what `MyHiFi.Peripheral.PiTft` builds from the events of the
  `:player` topic, and it returns a tree. It talks to no hardware and it runs no
  process, so a test draws it to a PNG and a person looks at the file.

  The layout is deliberately plain. A person reads this screen from a chair, across
  a room, so the title takes the largest text that fits two lines.

  A browse view comes with `MyHiFi.DeviceUi`, which owns the list and the selected
  index. This module draws no list today.
  """

  use Emerge.UI

  alias Emerge.UI.{Background, Border, Font}
  alias MyHiFi.Device.Identity
  alias MyHiFi.Screen.{Badge, Bar, Battery, Clock, Network, Row}

  @width 320
  @height 240

  @typedoc """
  What the screen draws.

  `state` decides the whole picture. `:stopped` shows the name of the device,
  because a person who sees nothing else needs to know that the device is awake.

  `device_name` is that name, and `splash_path` is the disk path of the picture that a
  person chose for that moment, or `nil` for a device with none. A device with a
  picture draws it over the whole screen, and the name sits in a band at the foot of
  it. See `MyHiFi.Device.Identity`.

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
          device_name: String.t(),
          splash_path: String.t() | nil,
          title: String.t() | nil,
          subtitle: String.t() | nil,
          message: String.t() | nil,
          artwork_path: String.t() | nil,
          accent: {0..255, 0..255, 0..255} | nil,
          live?: boolean(),
          battery_percent: 0..100 | nil,
          low_battery?: boolean(),
          percent: 0..100,
          position_ms: non_neg_integer(),
          duration_ms: pos_integer() | nil,
          network: Network.connection() | nil,
          volume_percent: 0..100 | nil
        }

  @doc "The size that this screen draws at."
  @spec size() :: {pos_integer(), pos_integer()}
  def size, do: {@width, @height}

  @doc "A view that shows nothing playing."
  @spec new() :: view()
  def new do
    %{
      state: :stopped,
      device_name: Identity.default_name(),
      splash_path: nil,
      title: nil,
      subtitle: nil,
      message: nil,
      artwork_path: nil,
      accent: nil,
      live?: false,
      battery_percent: nil,
      low_battery?: false,
      percent: 0,
      position_ms: 0,
      duration_ms: nil,
      network: nil,
      volume_percent: nil
    }
  end

  @doc """
  The view that a stop leaves.

  A stop clears the track. It clears neither what the hardware says nor what the device
  is called, so the charge of the cell, the name and the picture stay.
  """
  @spec stopped(view()) :: view()
  def stopped(view) do
    %{
      new()
      | battery_percent: view.battery_percent,
        low_battery?: view.low_battery?,
        device_name: view.device_name,
        splash_path: view.splash_path,
        network: view.network,
        volume_percent: view.volume_percent
    }
  end

  @doc "Draw one view."
  @spec render(view()) :: Emerge.tree()
  def render(%{state: :stopped, splash_path: path} = view) when is_binary(path), do: splash(view)

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
  def status_text(%{state: :stopped} = view), do: view.device_name
  def status_text(%{state: :failed}), do: "Failed"
  def status_text(%{state: :buffering, percent: percent}), do: "Buffering #{percent}%"
  def status_text(%{state: :paused}), do: "Paused"
  def status_text(%{live?: true}), do: "Live"
  def status_text(_view), do: "Playing"

  # **The picture fills the screen, and a band at the foot carries the name.** That is the
  # layout of `MyHiFi.Peripheral.PirateAudio.Screen`, and the reason is the same one: no
  # measurement of a picture says whether text over it reads, because the variance of
  # the pixels hides letters and a mean says nothing about variance. A flat band
  # flattens both, so one code path serves every picture. Read that module for why the
  # band is flat and not a gradient.
  defp splash(view) do
    el(
      [
        width(px(@width)),
        height(px(@height)),
        Background.image({:path, view.splash_path}, fit: :cover)
      ],
      column([width(fill()), height(fill())], [
        splash_battery(view),
        el([width(fill()), height(fill())], none()),
        splash_name(view)
      ])
    )
  end

  # The status row is absent from this layout, so what the hardware says sits over the
  # picture, on a band that keeps it readable. **The row draws for a device on the mains
  # as well**, because a device with no gauge can still stand beside a router that is off.
  defp splash_battery(view) do
    Row.ends([network(view)], [splash_gauge(view)], padding: {12, 10})
  end

  defp splash_gauge(%{battery_percent: nil}), do: none()

  defp splash_gauge(view) do
    Badge.render(Battery.render(view.battery_percent, view.low_battery?), padding: {6, 4})
  end

  defp splash_name(view) do
    el(
      [width(fill()), padding_xy(16, 14), Background.color(color_rgba(0, 0, 0, 0.72))],
      paragraph([width(fill()), Font.size(24), Font.color(color(:slate, 50))], [
        text(view.device_name)
      ])
    )
  end

  defp status_row(view) do
    Row.ends(
      [
        el(
          [
            padding_xy(8, 3),
            Border.rounded(999),
            Background.color(status_colour(view)),
            Font.size(13),
            Font.color(color(:slate, 950))
          ],
          text(status_text(view))
        )
      ],
      [
        network(view),
        el([Font.size(13), Font.color(color(:slate, 500))], text(elapsed(view))),
        battery(view)
      ],
      spacing: 8
    )
  end

  # **A network that carries the music draws nothing.** A person whose music plays needs
  # no mark that says so. `MyHiFi.Screen.Network` gives nothing for that state,
  # so this needs no test of its own.
  #
  # It sits beside the battery, because both say what the hardware is doing and a person
  # looks in one place for that.
  defp network(view) do
    el([center_y()], Network.render(view.network))
  end

  # **A device on the mains draws no battery at all.** It has no gauge, so it publishes
  # no charge, and a battery at 0 would be a lie. See `MyHiFi.Peripheral.Battery`.
  defp battery(%{battery_percent: nil}), do: none()

  defp battery(view) do
    el([center_y()], Battery.render(view.battery_percent, view.low_battery?))
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

  # The artwork is a square thumbnail, 120 pixels on each side. A track that has
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

  # **The level takes the place of the progress bar while a person sets it.** A person
  # holding a button is looking for the number, and a second bar would ask them which
  # one moved. The progress comes back when the level goes.
  #
  # Amber, and not the accent of the artwork, so a person reads at a glance that this
  # bar is not the place of the track.
  defp progress(%{volume_percent: percent}) when is_integer(percent) do
    column([width(fill()), spacing(4)], [
      Row.ends([volume_words("VOLUME")], [volume_words("#{percent}%")]),
      bar(percent / 100, color(:amber, 400))
    ])
  end

  defp progress(%{duration_ms: nil}), do: none()

  defp progress(view), do: bar(played(view), accent(view, color(:emerald, 500)))

  defp volume_words(words) do
    el([Font.size(13), Font.color(color(:slate, 400))], text(words))
  end

  # The bar sits inside the padding of the body, so it is that much narrower than the
  # glass. `MyHiFi.Screen.Bar` draws the two rectangles and it sets the least width of the
  # part that is full.
  defp bar(part, colour) do
    Bar.render(part,
      width: @width - 32,
      height: 6,
      radius: 3,
      track: color(:slate, 800),
      fill: colour
    )
  end

  # `use Emerge.UI` brings its own `min/2`, which builds a layout constraint and not a
  # number, so this names the `Kernel` one.
  defp played(view), do: Kernel.min(view.position_ms, view.duration_ms) / view.duration_ms

  defp elapsed(%{state: :stopped}), do: ""
  defp elapsed(%{duration_ms: nil} = view), do: Clock.text(view.position_ms)

  defp elapsed(view), do: "#{Clock.text(view.position_ms)} / #{Clock.text(view.duration_ms)}"

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
end
