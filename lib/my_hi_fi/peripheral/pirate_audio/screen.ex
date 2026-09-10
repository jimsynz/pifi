defmodule MyHiFi.Peripheral.PirateAudio.Screen do
  @moduledoc """
  The now playing view of the Pirate Audio, as an Emerge tree.

  This module holds the layout of a 240 by 240 screen and nothing else. It reads a
  `t:view/0`, which is what `MyHiFi.Peripheral.PirateAudio` builds from the events of
  the `:player` topic, and it gives a tree. It talks to no hardware and it holds no
  process, so a test draws it to a PNG and a person looks at the file.

  **The artwork fills the screen, and the words sit on top of it.** That is the whole
  design. The screen is square and small, and a person reads it from a chair, so one
  picture, two lines of text and one thin bar say more than a row of pills.

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

  ## The bar, and what it costs

  A bar means a draw for each `MyHiFi.Event.Player.Progress` event, which is one each
  second, and each draw of this screen decodes a JPEG and scales it to cover 240 by 240.
  An earlier version of this module drew no bar for that reason and named no measurement.

  A measurement on the board on 2026-09-09 gives 26 ms to render a frame that holds a
  cover, and 35 ms to write it over SPI. One draw each second is therefore 6 percent of
  one of the four cores, and the screen holds the bar.

  **A live stream draws no bar**, because it has no end. It shows the time from the
  start of the stream, which is what `MyHiFi.Event.Player.Progress` gives it.
  """

  use Emerge.UI

  alias Emerge.UI.{Background, Font}
  alias MyHiFi.Device.Identity
  alias MyHiFi.Screen.{Badge, Bar, Battery, Clock, Network, Row}

  @width 240
  @height 240

  # The scrim pads its words from the edge of the glass by this much on each side, and
  # the bar inside it is that much narrower than the screen. See `played_width/1`.
  @scrim_padding 14

  @bar_height 4

  @typedoc """
  What the screen draws.

  `state` decides the words. `artwork_path` is the disk path of a thumbnail, or `nil`
  for a track that holds no picture, and the screen then draws a plain dark field.

  `device_name` is the name that a person gave the device, and the screen shows it when
  the player plays nothing. `splash_path` is the disk path of the picture for that
  moment, and it fills the field in the place of the dark one. See
  `MyHiFi.Device.Identity`.

  `position_ms` is where the track is now, and `duration_ms` is how long it runs. A
  live stream holds `nil` for the second one, and the screen then draws the time and no
  bar.

  `network` is what the interfaces of the device are doing, and the screen says nothing
  about a network that carries the music. See `MyHiFi.Screen.Network`.

  `volume_percent` is the level that a person is setting now, and it is `nil` at every
  other moment. A level that stayed on the glass would take the room of the subtitle
  for a number that no person is reading. See `MyHiFi.Peripheral.PirateAudio`.
  """
  @type view :: %{
          state: :stopped | :buffering | :playing | :paused | :failed,
          device_name: String.t(),
          splash_path: String.t() | nil,
          title: String.t() | nil,
          subtitle: String.t() | nil,
          message: String.t() | nil,
          artwork_path: String.t() | nil,
          low_battery?: boolean(),
          battery_percent: 0..100 | nil,
          safe_to_switch_off?: boolean(),
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
      low_battery?: false,
      battery_percent: nil,
      safe_to_switch_off?: false,
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
  def render(view) do
    el(
      [width(px(@width)), height(px(@height)), field(view)],
      column([width(fill()), height(fill())], [top_row(view), spacer(), scrim(view)])
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

  A device that is ready for the switch says so, under the warning of a flat cell. A
  person who reads both must charge it before they read anything else. See
  `MyHiFi.SwitchOff`.
  """
  @spec headline(view()) :: String.t()
  def headline(%{low_battery?: true}), do: "LOW BATTERY\nCHARGE NOW"
  def headline(%{safe_to_switch_off?: true}), do: "SAFE TO\nSWITCH OFF"
  def headline(%{title: title}) when is_binary(title), do: title
  def headline(%{state: :failed} = view), do: view.message || "Failed"
  def headline(%{state: :buffering}), do: "Buffering"
  def headline(%{state: :stopped} = view), do: view.device_name
  def headline(_view), do: "Nothing is playing"

  # The artwork covers the screen, and a track with none gets the slate that the rest of
  # this firmware uses, so the words sit on a field that reads the same way.
  #
  # A device that plays nothing draws the picture that a person chose, and the scrim
  # keeps the name readable over it in the way that it does over a cover.
  defp field(%{artwork_path: path}) when is_binary(path),
    do: Background.image({:path, path}, fit: :cover)

  defp field(%{state: :stopped, splash_path: path}) when is_binary(path),
    do: Background.image({:path, path}, fit: :cover)

  defp field(_view), do: Background.color(color(:slate, 950))

  # The picture takes every row that the words leave.
  defp spacer, do: el([width(fill()), height(fill())], none())

  # The top row holds what the hardware says, over the artwork, because the foot of the
  # screen belongs to the words. The network sits on the left and the battery on the
  # right, so neither one moves when the other goes.
  #
  # The band behind each one is what keeps it readable over a bright picture, in the way
  # that the scrim keeps the words readable.
  defp top_row(view), do: Row.ends([network(view)], [battery(view)], padding: {10, 8})

  # **A device on the mains draws no battery at all.** It holds no gauge, so it publishes
  # no charge, and a battery at 0 would be a lie. See `MyHiFi.Peripheral.Battery`.
  defp battery(%{battery_percent: nil}), do: none()

  defp battery(view) do
    Badge.render(Battery.render(view.battery_percent, view.low_battery?))
  end

  # **A network that carries the music draws nothing.** A person whose music plays needs
  # no mark that says so, and this corner is 240 pixels wide.
  # `MyHiFi.Screen.Network` gives nothing for that state, so this needs no test
  # of its own.
  #
  # The band behind it is the one that the battery holds, because the mark sits over the
  # artwork and a bright picture would take it away.
  defp network(%{network: :internet}), do: none()
  defp network(%{network: nil}), do: none()

  defp network(view), do: Badge.render(Network.render(view.network))

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
        padding_xy(@scrim_padding, 12),
        spacing(3),
        Background.color(band(view))
      ],
      [title(view), subtitle(view), timeline(view)]
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
  # Green says that a person may act, where rose says that they must.
  defp band(%{safe_to_switch_off?: true}), do: color_rgba(6, 78, 59, 0.9)
  defp band(_view), do: color_rgba(0, 0, 0, 0.72)

  # The subtitle of a track says nothing beside a warning to charge the cell, nor beside
  # a device that waits for a hand on the switch.
  defp subtitle(%{low_battery?: true}), do: none()
  defp subtitle(%{safe_to_switch_off?: true}), do: none()
  defp subtitle(%{subtitle: nil}), do: none()

  defp subtitle(view) do
    paragraph([width(fill()), Font.size(14), Font.color(color(:slate, 300))], [
      text(view.subtitle)
    ])
  end

  # The time and the bar say the same thing in two ways, and a person needs both: the
  # bar says how much of the track is left at a glance, and the numbers say how much
  # that is. They sit together under the subtitle, in the band that keeps them readable.
  #
  # **A warning takes the place of the track**, so a flat cell and a hand on the switch
  # both take the time away with the subtitle. A device that plays nothing has no time
  # to show, and a fault has none that means anything.
  # **The level takes the place of the timeline while a person sets it.** A person
  # holding a button is looking for the number, and the two cannot both sit in a band
  # that holds 240 pixels. The timeline comes back when the level goes.
  defp timeline(%{volume_percent: percent}) when is_integer(percent) do
    column([width(fill()), spacing(5)], [volume_words(percent), volume_bar(percent)])
  end

  defp timeline(%{low_battery?: true}), do: none()
  defp timeline(%{safe_to_switch_off?: true}), do: none()
  defp timeline(%{state: :stopped}), do: none()
  defp timeline(%{state: :failed}), do: none()

  defp timeline(view), do: column([width(fill()), spacing(5)], [times(view), bar(view)])

  # A live stream shows the time from the start of it, and it has no end to show.
  defp times(%{duration_ms: nil} = view), do: el(time_style(), text(Clock.text(view.position_ms)))

  defp times(view) do
    Row.ends(
      [el(time_style(), text(Clock.text(view.position_ms)))],
      [el(time_style(), text(Clock.text(view.duration_ms)))]
    )
  end

  defp time_style, do: [Font.size(12), Font.color(color(:slate, 300))]

  defp volume_words(percent) do
    Row.ends([el(time_style(), text("VOLUME"))], [el(time_style(), text("#{percent}%"))])
  end

  # The accent of the product, and not the white of the timeline, so a person reads at
  # a glance that this bar is not the place of the track.
  defp volume_bar(percent), do: bar(percent / 100, color(:amber, 400))

  defp bar(%{duration_ms: nil}), do: none()

  defp bar(view), do: bar(played(view), color(:slate, 50))

  # The bar sits inside the padding of the scrim, so it is that much narrower than the
  # glass. `MyHiFi.Screen.Bar` holds the two rectangles and the least width of the
  # part that is full.
  defp bar(part, colour) do
    Bar.render(part,
      width: @width - 2 * @scrim_padding,
      height: @bar_height,
      radius: 2,
      track: color_rgba(255, 255, 255, 0.28),
      fill: colour
    )
  end

  # `use Emerge.UI` brings its own `min/2`, which builds a layout constraint and not a
  # number, so this names the `Kernel` one.
  defp played(view), do: Kernel.min(view.position_ms, view.duration_ms) / view.duration_ms
end
