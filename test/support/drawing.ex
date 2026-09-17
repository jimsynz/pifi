defmodule PiFi.Test.Drawing do
  @moduledoc """
  Draws one Emerge tree and gives the pixels, for a test that reads them.

  **Emerge 0.4 draws for a renderer and not for a call.** A test that wants the
  pixels of one tree therefore starts a renderer, uploads the tree, takes the frame,
  and gives the renderer back. `PiFi.Screen.Renderer` is the same path that a
  screen of the device takes, so a test reads what a person sees.

  A renderer of its own for each call costs a few milliseconds and keeps one test
  from reading the frame of another.
  """

  alias PiFi.Screen.Renderer

  @doc """
  The pixels of one tree, as RGBA, four bytes for each one.

  **It draws the tree twice, and it gives the second answer.** Emerge reads a picture
  after it draws the tree and sends a frame for each step, and
  `PiFi.Screen.Renderer.pixels/2` takes frames until 50 ms pass with none. A machine
  that runs the whole suite at once can take longer than that to decode one JPEG, and
  the answer then holds the tree without its picture. A renderer keeps what it decoded,
  so the second draw holds the picture whatever the load. That is what a screen of the
  device shows as well: it draws again for each event of the player.
  """
  @spec pixels(Emerge.tree(), pos_integer(), pos_integer(), keyword()) :: binary()
  def pixels(tree, width, height, assets \\ Renderer.assets()) do
    {:ok, renderer} = Renderer.start({width, height}, assets)

    try do
      {:ok, _first} = Renderer.pixels(renderer, tree)
      {:ok, pixels} = Renderer.pixels(renderer, tree)

      pixels
    after
      Renderer.stop(renderer)
    end
  end
end
