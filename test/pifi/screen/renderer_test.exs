defmodule PiFi.Screen.RendererTest do
  @moduledoc """
  The renderer that each screen of the device draws with.

  **Emerge reads a picture after it draws the tree.** It sends a frame for each step
  of that, and it draws a placeholder in the place of a picture that is still
  loading, so the frame that a screen wants is the last one of an upload and not the
  first. A screen that took the first one wrote the placeholder to the panel.
  """

  use ExUnit.Case, async: false

  use Emerge.UI

  alias Emerge.UI.Background
  alias PiFi.Screen.Renderer

  # A JPEG of 16 by 16, so a test needs no file of the repository.
  @jpeg Base.decode64!(
          "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABQODxIPDRQSEBIXFRQYHjIhHhwcHj0sLiQySUBMS0dARk" <>
            "VQWnNiUFVtVkVGZIhlbXd7gYKBTmCNl4x9lnN+gXz/2wBDARUXFx4aHjshITt8U0ZTfHx8fHx8fHx8" <>
            "fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHz/wAARCAAQABADASIAAhEBAx" <>
            "EB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAA" <>
            "AAAAAAAAAAAABAb/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCaAMoH/9k="
        )

  @size {320, 240}

  setup do
    directory = Path.join(PiFi.Cache.directory(), "artwork")
    File.mkdir_p!(directory)

    # The name of each test holds the picture once. Emerge keeps a decoded picture
    # under the name that it read, so a name that another test used already is a
    # picture that needs no reading and the race never happens.
    path = Path.join(directory, "renderer_#{System.unique_integer([:positive])}.thumbnail")
    File.write!(path, @jpeg)
    on_exit(fn -> File.rm(path) end)

    {:ok, renderer} = Renderer.start(@size)
    on_exit(fn -> Renderer.stop(renderer) end)

    %{renderer: renderer, path: path}
  end

  defp tree(path) do
    {across, down} = @size

    el(
      [
        width(px(across)),
        height(px(down)),
        Background.image({:path, path}, fit: :cover)
      ],
      none()
    )
  end

  describe "a tree that names a picture" do
    # **This is the fault that the screens of both boards showed.** The first draw
    # wrote the placeholder of Emerge, and the picture reached the glass only when
    # something else made the screen draw again. A screen that plays draws each
    # second and healed itself, and an idle screen held the placeholder.
    test "the first draw holds the picture, and not a placeholder", context do
      %{renderer: renderer, path: path} = context
      tree = tree(path)

      assert {:ok, first} = Renderer.pixels(renderer, tree)
      assert {:ok, second} = Renderer.pixels(renderer, tree)

      assert first == second
    end

    test "each draw of one tree gives the same pixels", context do
      %{renderer: renderer, path: path} = context
      tree = tree(path)

      drawn =
        for _ <- 1..4 do
          assert {:ok, pixels} = Renderer.pixels(renderer, tree)
          pixels
        end

      assert Enum.uniq(drawn) == [hd(drawn)]
    end
  end

  describe "the size of a frame" do
    test "it holds four bytes for each pixel", %{renderer: renderer, path: path} do
      {across, down} = @size

      assert {:ok, pixels} = Renderer.pixels(renderer, tree(path))
      assert byte_size(pixels) == across * down * 4
    end
  end
end
