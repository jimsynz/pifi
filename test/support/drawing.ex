defmodule MyHiFi.Test.Drawing do
  @moduledoc """
  Draws one Emerge tree and gives the pixels, for a test that reads them.

  **Emerge 0.4 draws for a renderer and not for a call.** A test that wants the
  pixels of one tree therefore starts a renderer, uploads the tree, takes the frame,
  and gives the renderer back. `MyHiFi.Screen.Renderer` is the same path that a
  screen of the device takes, so a test reads what a person sees.

  A renderer of its own for each call costs a few milliseconds and keeps one test
  from reading the frame of another.
  """

  alias MyHiFi.Screen.Renderer

  @doc """
  The pixels of one tree, as RGBA, four bytes for each one.
  """
  @spec pixels(Emerge.tree(), pos_integer(), pos_integer(), keyword()) :: binary()
  def pixels(tree, width, height, assets \\ Renderer.assets()) do
    {:ok, renderer} = Renderer.start({width, height}, assets)

    try do
      {:ok, pixels} = Renderer.pixels(renderer, tree)

      pixels
    after
      Renderer.stop(renderer)
    end
  end
end
