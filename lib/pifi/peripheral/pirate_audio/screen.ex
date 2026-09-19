defmodule PiFi.Peripheral.PirateAudio.Screen do
  @moduledoc """
  The now playing view of the Pirate Audio, as an Emerge tree.

  This module owns the layout of a 240 by 240 screen and nothing else. It reads a
  `t:view/0`, which is what `PiFi.Peripheral.PirateAudio` builds from the events of
  the `:player` topic, and it returns a tree. It talks to no hardware and it runs no
  process, so a test draws it to a PNG and a person looks at the file.

  **The artwork fills the screen, and the words sit on top of it.** That is the whole
  design. The screen is square and small, and a person reads it from a chair, so one
  picture, two lines of text and one thin bar say more than a row of pills.

  ## How the words stay readable

  A colour that a picture gives cannot be trusted here, and this is the part that reads
  wrong at first. `PiFi.Artwork.Accent` gives the colour that a picture has **most**
  of, and over that same picture it is therefore the colour most likely to disappear.
  The accent belongs on the slate of the web page and of the PiTFT, where it has a known
  background. It has none here.

  **A measurement of the picture cannot be trusted either.** The mean lightness of the
  place where the words go says nothing about the variance of it, and it is the variance
  that hides text: a bright window behind a dark coat takes away half the letters
  whatever single colour a caller picks.

  This draws a panel instead, which is a card of near opaque ink that stands over the
  foot of the picture. It hides the picture where the words go, so light text on it
  reads over every picture and one code path serves them all. Emerge has no shadow for
  text, so a shadow was never an answer here: `Emerge.UI.Border` gives `shadow/1` and
  `glow/2`, and those draw around the frame of an element and not around a letter.

  **An earlier version faded a band from nothing to near black**, and that band let a
  bright cover through at the top of it. The style of the product asks for a flat fill,
  a hard border and no gradient anywhere, and here the style and the legibility want
  the same thing. See `PiFi.Screen.Style`.

  ## The bar, and what it costs

  A bar means a draw for each `PiFi.Event.Player.Progress` event, which is one each
  second, and each draw of this screen decodes a JPEG and scales it to cover 240 by 240.
  An earlier version of this module drew no bar for that reason and named no measurement.

  A measurement on the board on 2026-09-09 gives 26 ms to render a frame with a
  cover, and 35 ms to write it over SPI. One draw each second is therefore 6 percent of
  one of the four cores, and the screen therefore draws the bar.

  **A live stream draws no bar**, because it has no end. It shows the time from the
  start of the stream, which is what `PiFi.Event.Player.Progress` gives it.
  """

  use Emerge.UI

  alias Emerge.UI.{Background, Font}
  alias PiFi.Device.Identity
  alias PiFi.Screen.{Badge, Bar, Battery, Clock, Network, Row, Style}

  @width 240
  @height 240

  # **The panel of the words stands away from the edge of the glass by this much.** The
  # offset shadow falls into that space, so a margin smaller than the offset would put
  # the shadow off the glass and the panel would read as a band and not as a card.
  @panel_margin 6

  # The space between the border of the panel and the words inside it.
  @panel_padding 9

  # A bar carries a border of 2 on each side, so a bar of 8 leaves 4 for the part that
  # is full. See `PiFi.Screen.Bar`.
  @bar_height 8

  @typedoc """
  What the screen draws.

  `state` decides the words. `artwork_path` is the disk path of a thumbnail, or `nil`
  for a track with no picture, and the screen then draws a plain dark field.

  `device_name` is the name that a person gave the device, and the screen shows it when
  the player plays nothing. `splash_path` is the disk path of the picture for that
  moment, and it fills the field in the place of the dark one. See
  `PiFi.Device.Identity`.

  `position_ms` is where the track is now, and `duration_ms` is how long it runs. A
  live stream gives `nil` for the second one, and the screen then draws the time and no
  bar.

  `network` is what the interfaces of the device are doing, and the screen says nothing
  about a network that carries the music. See `PiFi.Screen.Network`.

  `volume_percent` is the level that a person is setting now, and it is `nil` at every
  other moment. A level that stayed on the glass would take the room of the subtitle
  for a number that no person is reading. See `PiFi.Peripheral.PirateAudio`.
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
      column([width(fill()), height(fill())], [top_row(view), spacer(), panel(view)])
    )
  end

  @doc """
  The word in the chip at the head of the screen.

  **A cell that is nearly flat wins over the state of the player**, for the reason that
  `headline/1` gives: the one thing that a person must do is charge the device.

      iex> PiFi.Peripheral.PirateAudio.Screen.status_text(%{state: :paused, low_battery?: false})
      "PAUSED"
  """
  @spec status_text(map()) :: String.t()
  def status_text(%{low_battery?: true}), do: "CHARGE"
  def status_text(%{state: :failed}), do: "FAILED"
  def status_text(%{state: :buffering}), do: "BUFFERING"
  def status_text(%{state: :paused}), do: "PAUSED"
  def status_text(_view), do: "PLAYING"

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
  `PiFi.SwitchOff`.
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
  # A device that plays nothing draws the picture that a person chose, and the panel
  # keeps the name readable over it in the way that it does over a cover.
  defp field(%{artwork_path: path}) when is_binary(path),
    do: Background.image({:path, path}, fit: :cover)

  defp field(%{state: :stopped, splash_path: path}) when is_binary(path),
    do: Background.image({:path, path}, fit: :cover)

  defp field(_view), do: Background.color(Style.ground())

  # The picture takes every row that the words leave.
  defp spacer, do: el([width(fill()), height(fill())], none())

  # The top row draws the state of the player and what the hardware says, over the
  # artwork, because the foot of the screen belongs to the words. **The chip sits on the
  # left and the hardware on the right**, which is the row that
  # `PiFi.Peripheral.PiTft.Screen` draws, so a person who owns both devices reads one
  # layout.
  #
  # **The two marks of the hardware sit bare on the picture, and the chip is the one
  # thing in a panel.** An earlier version gave each mark a panel of its own, and three
  # boxes in a row of 240 pixels read as clutter. The chip keeps its panel because the
  # panel is the block of colour that says the state.
  defp top_row(view) do
    Row.ends([status(view)], [network(view), battery(view)],
      padding: {8, 8},
      spacing: 5
    )
  end

  # A cell that is nearly flat takes the colour of a fault, because `status_text/1` puts
  # the warning in the chip and a warning in the colour of a track says nothing.
  defp status_colour(%{low_battery?: true}), do: Style.coral()
  defp status_colour(view), do: Style.state_colour(view.state)

  # **A device that plays nothing draws no chip.** The card at the foot carries the name
  # of the device in that moment, and a chip that said `STOPPED` beside it would say the
  # same thing again in a corner that holds 240 pixels.
  defp status(%{state: :stopped}), do: none()

  defp status(view) do
    Badge.render(
      el(Style.display(11) ++ [Font.color(Style.ground())], text(status_text(view))),
      fill: status_colour(view),
      padding: {6, 2}
    )
  end

  # **A device on the mains draws no battery at all.** It has no gauge, so it publishes
  # no charge, and a battery at 0 would be a lie. See `PiFi.Peripheral.Battery`.
  defp battery(%{battery_percent: nil}), do: none()

  defp battery(view) do
    el([center_y()], Battery.render(view.battery_percent, view.low_battery?))
  end

  # **A network that carries the music draws nothing.** A person whose music plays needs
  # no mark that says so, and this corner is 240 pixels wide.
  # `PiFi.Screen.Network` gives nothing for that state, so this needs no test
  # of its own.
  #
  defp network(%{network: :internet}), do: none()
  defp network(%{network: nil}), do: none()

  defp network(view), do: el([center_y()], Network.render(view.network))

  # A warning draws its card whatever else is on the glass.
  defp panel(%{low_battery?: true} = view), do: card(view)
  defp panel(%{safe_to_switch_off?: true} = view), do: card(view)

  # **A device that no person named draws no card over the mark of the product.** The
  # mark carries the name of the product already, so a card would write the same word
  # twice and cut the mark in half while it did. A person who names the device gets
  # the card back, because the mark cannot carry a name that it was drawn without.
  defp panel(%{state: :stopped, splash_path: path} = view) when is_binary(path) do
    if named?(view), do: card(view), else: none()
  end

  defp panel(view), do: card(view)

  defp named?(view), do: view.device_name != Identity.default_name()

  # **The card stands away from three edges of the glass, and the shadow falls into that
  # space.** A panel flush to the edges would read as a band, and the offset shadow is
  # what makes this the style of the product and not a dark strip.
  defp card(view) do
    el(
      [width(fill()), padding_each(0, @panel_margin, @panel_margin, @panel_margin)],
      column(
        [
          width(fill()),
          padding(@panel_padding),
          spacing(4),
          Background.color(band(view))
        ] ++ Style.edge() ++ [Style.offset()],
        [title(view), subtitle(view), timeline(view)]
      )
    )
  end

  # `paragraph/2` wraps and `el/2` with `text/1` does not. A podcast episode has a long
  # title, and one that does not wrap goes past the edge of the glass.
  #
  # **The heading keeps the case that the track gave it.** The display face is wide, and
  # a capital of it is wider still, so a long title in capitals runs off a glass of 240
  # pixels. Capitals are for the chip and for the labels, which this module writes and
  # which are short by rule. `headline/1` writes its warnings in capitals itself,
  # because those are words of this module and not of a track.
  defp title(view) do
    paragraph(
      [width(fill()), Font.color(words(view))] ++ Style.display(17),
      [text(headline(view))]
    )
  end

  # **A card of colour takes dark words, and the card of a track takes light ones.**
  # Ink on coral is two shades of light and a person reads it slowly, where the ground
  # on coral is the contrast that a warning needs. The website draws a coloured card
  # the same way.
  defp words(%{low_battery?: true}), do: Style.ground()
  defp words(%{safe_to_switch_off?: true}), do: Style.ground()
  defp words(_view), do: Style.ink()

  # A warning reads as a warning by its colour before a person reads the words, and coral
  # is what `PiFi.Peripheral.PiTft.Screen` already gives a fault. **A warning fills the
  # card with the colour and draws the words in ink**, where the card of a track is dark
  # and the words are light. A person reads the block of colour across a room, before
  # they read one letter of it.
  defp band(%{low_battery?: true}), do: Style.coral()
  # Green says that a person may act, where coral says that they must.
  defp band(%{safe_to_switch_off?: true}), do: Style.green()
  defp band(_view), do: Style.panel_over_art()

  # The subtitle of a track says nothing beside a warning to charge the cell, nor beside
  # a device that waits for a hand on the switch.
  defp subtitle(%{low_battery?: true}), do: none()
  defp subtitle(%{safe_to_switch_off?: true}), do: none()
  defp subtitle(%{subtitle: nil}), do: none()

  defp subtitle(view) do
    paragraph([width(fill()), Font.size(13), Font.color(Style.ink_dim())], [
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
  # that is 240 pixels wide. The timeline comes back when the level goes.
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

  # The times and the word `VOLUME` are labels and not prose, so they take the display
  # face in capitals, in the way that the labels of the website do.
  defp time_style, do: Style.display(11) ++ [Font.color(Style.ink_dim())]

  defp volume_words(percent) do
    Row.ends([el(time_style(), text("VOLUME"))], [el(time_style(), text("#{percent}%"))])
  end

  # Amber, which is the second colour of the mark, where the place of the track takes
  # cyan. A person reads at a glance that this bar is not the place of the track.
  defp volume_bar(percent), do: bar(percent / 100, Style.amber())

  defp bar(%{duration_ms: nil}), do: none()

  defp bar(view), do: bar(played(view), Style.cyan())

  # The bar sits inside the padding of the card, and the card inside the margin of the
  # glass, so it is that much narrower than the screen. `PiFi.Screen.Bar` draws the two
  # rectangles and it sets the least width of the part that is full.
  defp bar(part, colour) do
    Bar.render(part,
      width: @width - 2 * (@panel_margin + @panel_padding + 2),
      height: @bar_height,
      track: Style.ground(),
      fill: colour
    )
  end

  # `use Emerge.UI` brings its own `min/2`, which builds a layout constraint and not a
  # number, so this names the `Kernel` one.
  defp played(view), do: Kernel.min(view.position_ms, view.duration_ms) / view.duration_ms
end
