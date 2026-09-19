defmodule PiFi.Screen.Renderer do
  # **How long a screen waits for the frame that it asked for.** A measurement on the
  # board on 2026-09-09 gave 26 ms for a frame that holds a cover, so this is a bound
  # against a renderer that stopped and never against one that is working.
  @frame_ms 2_000

  # **How long a screen waits for the frame after the last one.** Emerge reads a
  # picture after it draws the tree, and it sends a frame for each step of that, so
  # the frame that holds the picture is the last one and not the first. A measurement
  # on the host on 2026-09-11 gave 2 ms to 7 ms between the frames of one upload.
  @settle_ms 50

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

  ## The frame arrives as a message, and more than one arrives

  `EmergeSkia.start/1` demands a live process for a headless renderer, and each
  `EmergeSkia.upload_tree/2` sends a frame to that process. **A frame arrives for each
  upload, and the tree that did not change gets one as well.**

  **One upload gives more than one frame, because Emerge reads a picture after it
  draws the tree.** The guide of Emerge says it plainly: asset loading is
  asynchronous, and Emerge draws a placeholder for a source that is still loading. A
  screen that took the first frame therefore wrote the placeholder to the panel, and
  the picture reached the glass only when something else made the screen draw again.
  A screen that plays shows a progress event each second and healed itself in one
  second. **An idle screen draws one time and held the placeholder.**

  `pixels/2` therefore takes frames until #{@settle_ms} ms pass with none, and it
  gives the last one. A measurement on the host on 2026-09-11 gave one to three
  frames for each upload, 2 ms to 7 ms apart, and the last one always held the
  picture.

  The first frame is bounded at #{@frame_ms} ms, which is a bound against a renderer
  that stopped. It takes the frames that an earlier wait left behind first, so a draw
  that timed out cannot make the next one draw the frame before it.

  ## What a runtime path may hold

  **Emerge refuses a path by its extension, and it reads no byte to decide.** A name
  of the cache carries no type, so a thumbnail is `<hash>.thumbnail`, and the default
  list of Emerge names `.png`, `.jpg` and five others. A screen that took the default
  drew the mark for a picture that it cannot read, in the place of the artwork.
  `assets/0` names the two that this firmware gives it.

  ## The typeface of the product

  **The screens of this device draw their headings in Archivo Black**, which is the
  display face of the PiFi mark and of the website. Neither this firmware nor the
  Nerves system held a font before, so the screens drew in the face that Skia uses
  when it finds no other, and that face is not the face of the product.

  `EmergeSkia.load_font_file/5` registers a file under a family name, and the
  registration belongs to one renderer, so `start/2` loads the file each time. A
  screen then names the family with `Emerge.UI.Font.family/1`.
  `PiFi.Screen.Style.display_face/0` is the one place that names it.

  **The file lives under `priv/static`, where the web interface also serves it.**
  Everything under `priv` goes into the firmware, so a second copy for the renderer
  would put 91 kB of the same bytes on a card that holds the music.

  **A renderer that cannot read the file still starts.** A screen that draws in
  another face is a screen that a person can read, and a screen that will not start
  is a black panel. See `load_display_face/1`.

  ## `rendering_api: :raster`

  The board holds no GPU that this firmware uses, and `config/target.exs` names
  `compiled_backends: []`, so the NIF that the device runs is the raster one. Naming
  the API here says the same thing in the one place that a reader of this module
  looks.
  """

  require Logger

  alias PiFi.Cache
  alias PiFi.Device.Identity
  alias PiFi.Screen.Style

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
    with {:ok, renderer} <-
           EmergeSkia.start(
             otp_app: :pifi,
             backend: :headless,
             rendering_api: :raster,
             width: width,
             height: height,
             assets: assets,
             headless: [target: self(), mode: :binary, pixel_format: :rgba8888]
           ) do
      load_display_face(renderer)

      {:ok, renderer}
    end
  end

  @doc """
  Draw one tree, and give the pixels of it.

  The pixels are RGBA, four bytes for each one, which is what
  `PiFi.Peripheral.PiTft.Ili9341.to_rgb565/1` and
  `PiFi.Peripheral.PirateAudio.St7789.to_rgb565/1` take.
  """
  @spec pixels(t(), Emerge.tree()) :: {:ok, binary()} | {:error, term()}
  def pixels(renderer, tree) do
    _left = drop_frames()

    EmergeSkia.upload_tree(renderer, tree)

    case frame(@frame_ms) do
      {:ok, frame} -> {:ok, settled(frame)}
      :none -> {:error, :no_frame}
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

  The cache keeps the thumbnails, and `PiFi.Artwork` names each one
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

  # **A face that will not load costs a screen nothing that a person cannot read.**
  # Emerge draws in the face that Skia uses when it finds no other, so the words stay
  # on the glass and only the shape of them changes. A renderer that refused to start
  # for a missing font would give a person a black panel instead.
  defp load_display_face(renderer) do
    path = Application.app_dir(:pifi, ["priv", "static", "fonts", "ArchivoBlack-Regular.ttf"])

    case EmergeSkia.load_font_file(renderer, Style.display_face(), 400, false, path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("The screens draw in another face: #{inspect(reason)}")

        :ok
    end
  end

  # The last frame of this upload. Each one after the first holds more of the picture
  # than the one before it, so the caller wants the one that no frame follows.
  defp settled(frame) do
    case frame(@settle_ms) do
      {:ok, later} -> settled(later)
      :none -> frame.storage.data
    end
  end

  defp frame(wait) do
    receive do
      {:emerge_skia_frame, frame} -> {:ok, frame}
    after
      wait -> :none
    end
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
