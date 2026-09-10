defmodule MyHiFi.Screen do
  @moduledoc """
  The parts that the screens of this device draw with.

  A peripheral owns its layout. `MyHiFi.Peripheral.PiTft.Screen` draws 320 by 240
  pixels and `MyHiFi.Peripheral.PirateAudio.Screen` draws 240 by 240, and the two
  therefore put things in different places. That is the rule that `MyHiFi.Peripheral`
  names, and this library does not take it away.

  **A part says what a thing looks like, and a layout says where it sits.** The shape
  of a battery, the two rectangles of a bar and the black band under a mark all read
  the same way on every screen of this device, so each one lives here and neither
  screen keeps a copy. A screen that draws a bar of another height and another colour
  passes those, and it still draws the bar that this device draws.

  The parts:

  - `MyHiFi.Screen.Badge` puts a mark on a dark band, so it reads over a picture.
  - `MyHiFi.Screen.Bar` draws a bar that is part full.
  - `MyHiFi.Screen.Battery` draws the charge of the cell.
  - `MyHiFi.Screen.Clock` writes the time of a track as words.
  - `MyHiFi.Screen.Network` draws the state of the network.
  - `MyHiFi.Screen.Row` puts one thing at each end of a row.

  A part takes a value and its options, and it returns an `t:Emerge.tree/0`. It reads
  no event, it runs no process and it talks to no hardware, so a test draws it to a PNG
  and a person looks at the file.

  **The web interface does not use this library.** A browser has CSS, and a page
  that drew a battery out of rectangles would throw that away. See
  `MyHiFiWeb.CoreComponents`.
  """
end
