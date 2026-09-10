defmodule MyHiFi.Screen.Network do
  @moduledoc """
  A network, drawn for a screen that Emerge renders.

  `MyHiFi.Peripheral.PiTft.Screen` and `MyHiFi.Peripheral.PirateAudio.Screen` both draw
  one, and the shape of it belongs to neither of them. **This is a component and not a
  layout**: each screen still decides where the mark sits and how large it is, which is
  the rule that `MyHiFi.Peripheral` names. It is `MyHiFi.Screen.Battery` for the
  network.

  **A screen draws this only when the network cannot carry the music.** A person whose
  music plays needs no mark that says the network works, and 240 pixels hold no room for
  one. `render/2` therefore gives nothing at all for that state, so a screen needs no
  test of its own.

  `connection/1` reduces what `MyHiFi.Device.network!/0` gives to the one state that
  decides the mark. **A screen keeps that atom and not the report**, because the report
  carries the strength of the signal and that number moves all the time: a view that
  held it would draw a frame each time it did.

  ## Why it is drawn and not an image

  The reason is the one that `MyHiFi.Screen.Battery` gives. Emerge draws an SVG
  with `Emerge.UI.svg/2`, which takes a source that it must read from the disk, and a
  runtime path of this firmware is a thumbnail of the cache and nothing else. Rectangles
  need no file, no allowlist and no decode, and they stay sharp at 11 pixels tall where
  a scaled image does not.

  **The arcs of the usual Wi-Fi mark are the reason that this draws bars.** Emerge has
  no arc, and three rectangles of rising height read as a network at this size where a
  ring of rounded rectangles reads as nothing.

  ## The mark says that something is wrong, and the colour says what

  **A mark that is there at all is the signal**, because a network that carries the music
  draws none. That is the fact that a person must read, and it rests on the mark and not
  on any colour of it.

  The colour then says which of the two faults it is, and the two colours are the ones
  that this firmware already gives a state of the player. See
  `MyHiFi.Peripheral.PiTft.Screen`:

  - **`:lan` draws amber**, which is the colour of a device that is working on
    something. The radio link works and the network stops beyond it, so a person looks
    at their router and not at this device.
  - **`:disconnected` draws rose**, which is the colour of a fault. Nothing carries the
    link at all, and rose is the worse of the two colours for the worse of the two
    states.

  A reader who cannot tell amber from rose still reads that something is wrong, because
  the mark is there at all. They lose which of the two it is, and the network page of
  the web interface names the state of each interface.

  **A mark of one colour and an exclamation mark beside it was the try before this.** It
  needed 4 more pixels of width for a shape that a person had to look at twice, where a
  colour says the same thing in the pixels that the bars already hold.
  """

  use Emerge.UI

  alias Emerge.UI.{Background, Border}

  @typedoc "What VintageNet says one interface is doing."
  @type connection :: :internet | :lan | :disconnected

  # Best first. `connection/1` reads this order, so a device with a cable and
  # Wi-Fi takes the better of the two.
  @order [:internet, :lan, :disconnected]

  # Three bars of rising height, as a share of the height of the mark. A fourth bar
  # costs a pixel that 11 of them cannot spare.
  @bars [0.45, 0.72, 1.0]

  @bar_width 2
  @bar_spacing 1
  @default_height 11

  @doc """
  Draw the mark for one state of the network.

  It returns nothing at all for a network that carries the music, so a caller needs no
  test of its own: the screens draw whatever this gives.

  ## Options

  - `:height` - the height of the tallest bar, in pixels. #{@default_height} by default,
    which is the height of the body of `MyHiFi.Screen.Battery`, so the two sit
    level.
  """
  @spec render(connection() | nil, keyword()) :: Emerge.tree()
  def render(connection, opts \\ [])

  def render(:lan, opts), do: bars(tallest(opts), color(:amber, 400))

  def render(:disconnected, opts), do: bars(tallest(opts), color(:rose, 400))

  # A network that carries the music draws nothing, and so does a device that names no
  # interface.
  def render(_connection, _opts), do: none()

  @doc """
  The state of the device, from what `MyHiFi.Device.network!/0` gives.

  It is `nil` for a device that names no interface. A host build gives an empty list,
  because VintageNet is a target dependency, and a screen that knows nothing about the
  network must say nothing about it.

  **A device has more than one interface**, and Wi-Fi and a cable both count, so the
  best state of any of them is the state of the device.

      iex> MyHiFi.Screen.Network.connection([%{connection: :lan}, %{connection: :internet}])
      :internet

      iex> MyHiFi.Screen.Network.connection([])
      nil
  """
  @spec connection([map()]) :: connection() | nil
  def connection([]), do: nil

  def connection(interfaces) do
    states = Enum.map(interfaces, & &1.connection)

    Enum.find(@order, :disconnected, &(&1 in states))
  end

  defp tallest(opts), do: Keyword.get(opts, :height, @default_height)

  # **The bars need the height of the row and the alignment of each child.** A row that
  # hugs its content takes the height of its tallest child, and `align_bottom/0` on such
  # a row moves nothing: a first try drew three bars that hung from the top, and they
  # read as a ragged row and not as a signal.
  defp bars(tallest, colour) do
    row(
      [spacing(@bar_spacing), height(px(tallest))],
      Enum.map(@bars, &bar(round(tallest * &1), colour))
    )
  end

  defp bar(bar_height, colour) do
    el(
      [
        width(px(@bar_width)),
        height(px(bar_height)),
        align_bottom(),
        Background.color(colour),
        Border.rounded(1)
      ],
      none()
    )
  end
end
