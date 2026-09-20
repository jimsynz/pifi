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

  @attempts 25

  @doc """
  The pixels of one tree, as RGBA, four bytes for each one.

  **It draws until two draws agree.** Emerge reads a picture after it draws the tree
  and sends a frame for each step, and `PiFi.Screen.Renderer.pixels/2` takes frames
  until 50 ms pass with none. A machine running the whole suite at once can take
  longer than that to decode one JPEG, and the answer then holds the tree without its
  picture. A renderer keeps what it decoded, so a later draw holds it.

  This drew twice and gave the second answer before, and twice was not always enough:
  `PiFi.Peripheral.PiTftTest` failed on a loaded CI runner with a frame of flat
  background where the thumbnail should have been, and passed on the same commit
  elsewhere. Two draws that agree is the property that actually matters, because a
  picture that is still arriving changes the frame and one that has arrived does not.

  A tree with no picture agrees on the first pair and costs one extra draw. That is
  what a screen of the device does anyway: it draws again for each event of the player.
  """
  @spec pixels(Emerge.tree(), pos_integer(), pos_integer(), keyword()) :: binary()
  def pixels(tree, width, height, assets \\ Renderer.assets()) do
    {:ok, renderer} = Renderer.start({width, height}, assets)

    try do
      {:ok, first} = Renderer.pixels(renderer, tree)

      settled(renderer, tree, first, @attempts)
    after
      Renderer.stop(renderer)
    end
  end

  # Each attempt is a draw and at most the 50 ms that the renderer waits for a frame
  # with nothing after it, so the whole of this is a second and a half at worst. It
  # gives the last frame rather than raising: a test that reads a picture which never
  # arrived fails on what it drew, which says more than a timeout does.
  defp settled(_renderer, _tree, pixels, 0), do: pixels

  defp settled(renderer, tree, previous, attempts) do
    case Renderer.pixels(renderer, tree) do
      {:ok, ^previous} -> previous
      {:ok, pixels} -> settled(renderer, tree, pixels, attempts - 1)
    end
  end
end
