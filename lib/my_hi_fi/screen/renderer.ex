defmodule MyHiFi.Screen.Renderer do
  # **How long a screen waits for the frame that it asked for.** A measurement on the
  # board on 2026-09-09 gave 26 ms for a frame that holds a cover, so this is a bound
  # against a renderer that stopped and never against one that is working.
  @frame_ms 2_000

  @moduledoc """
  The Emerge renderer that a screen of this device draws with.

  **This firmware drives no window and no display server.** It renders to pixels and
  writes them to a panel over SPI, so each screen starts a headless renderer of its
  own, gives it a tree, and takes the bytes back.

  ## Why a renderer, and not one call

  Emerge 0.3 took a tree and gave the pixels back in one call, and 0.4 removed that:
  `EmergeSkia.render_to_pixels/2` now reads the last frame of a renderer that runs.
  A renderer therefore lives for as long as the screen does.

  The change pays for itself. A renderer keeps its surface, its fonts and its decoded
  pictures between frames, and it holds them for itself alone, so a draw of the same
  list costs less than a draw that built everything again.

  ## The frame arrives as a message

  `EmergeSkia.start/1` demands a live process for a headless renderer, and each
  `EmergeSkia.upload_tree/2` sends one frame to that process. **A frame arrives for
  each upload, and the tree that did not change gets one as well.**

  `pixels/2` therefore uploads and waits for the frame. A screen has nothing else to
  do while it draws, and the wait is bounded at #{@frame_ms} ms. It takes the frames
  that an earlier wait left behind first, so a draw that timed out cannot make the
  next one draw the frame before it.

  ## What a runtime path may hold

  **Emerge refuses a path by its extension, and it reads no byte to decide.** A name
  of the cache carries no type, so a thumbnail is `<hash>.thumbnail`, and the default
  list of Emerge names `.png`, `.jpg` and five others. A screen that took the default
  drew the mark for a picture that it cannot read, in the place of the artwork.
  `assets/0` names the two that this firmware gives it.

  ## `rendering_api: :raster`

  The board holds no GPU that this firmware uses, and `config/target.exs` names
  `compiled_backends: []`, so the NIF that the device runs is the raster one. Naming
  the API here says the same thing in the one place that a reader of this module
  looks.
  """

  require Logger

  alias MyHiFi.Cache
  alias MyHiFi.Device.Identity

  @typedoc "A renderer of Emerge, as `EmergeSkia.start/1` gives it."
  @type t :: reference() | struct()

  @doc """
  Start a renderer for one screen.

  The caller is the process that each frame goes to, so a screen calls this from its
  own process and takes the frames in `pixels/2`.

  A caller that names another allowlist gives one. A test of what Emerge refuses is
  the reason that this takes a second argument at all.
  """
  @spec start({pos_integer(), pos_integer()}, keyword()) :: {:ok, t()} | {:error, term()}
  def start(size, assets \\ assets())

  def start({width, height}, assets) do
    EmergeSkia.start(
      otp_app: :my_hi_fi,
      backend: :headless,
      rendering_api: :raster,
      width: width,
      height: height,
      assets: assets,
      headless: [target: self(), mode: :binary, pixel_format: :rgba8888]
    )
  end

  @doc """
  Draw one tree, and give the pixels of it.

  The pixels are RGBA, four bytes for each one, which is what
  `MyHiFi.Peripheral.PiTft.Ili9341.to_rgb565/1` and
  `MyHiFi.Peripheral.PirateAudio.St7789.to_rgb565/1` take.
  """
  @spec pixels(t(), Emerge.tree()) :: {:ok, binary()} | {:error, term()}
  def pixels(renderer, tree) do
    _left = drop_frames()

    EmergeSkia.upload_tree(renderer, tree)

    receive do
      {:emerge_skia_frame, frame} -> {:ok, frame.storage.data}
    after
      @frame_ms -> {:error, :no_frame}
    end
  end

  @doc """
  Give the renderer back.

  A renderer that does not stop cleanly is a fault of the native code, and a screen
  that is going away can do nothing about it, so this says what happened and carries
  on.
  """
  @spec stop(t()) :: :ok
  def stop(renderer) do
    case EmergeSkia.stop(renderer) do
      :ok -> :ok
      {:error, reason} -> Logger.error("The renderer did not stop: #{inspect(reason)}")
    end

    :ok
  end

  @doc """
  What Emerge may read from the disk while it draws.

  The cache keeps the thumbnails, and `MyHiFi.Artwork` names each one
  `<hash>.thumbnail`. The picture of the idle screen is a PNG that this firmware
  ships. See the module documentation for why the extension decides.
  """
  @spec assets() :: keyword()
  def assets do
    [
      runtime_paths: [
        enabled: true,
        allowlist: [Cache.directory(), Identity.splash_directory()],
        extensions: [".thumbnail", ".png"]
      ]
    ]
  end

  # A wait that timed out leaves its frame in the mailbox, and the frame after it is
  # the one that the caller asked for.
  defp drop_frames(dropped \\ 0) do
    receive do
      {:emerge_skia_frame, _frame} -> drop_frames(dropped + 1)
    after
      0 -> dropped
    end
  end
end
