defmodule MyHiFi.Peripheral.PiTft do
  @moduledoc """
  The 2.8 inch PiTFT screen.

  It takes the events of the `:player` topic, keeps what they say in a
  `t:MyHiFi.Peripheral.PiTft.Screen.view/0`, draws that view with Emerge, and writes
  the pixels to the ILI9341 over SPI.

      Player event
        -> the view                          (this module)
        -> Emerge tree                       (MyHiFi.Peripheral.PiTft.Screen)
        -> RGBA, 307 200 bytes               (EmergeSkia.render_to_pixels/2)
        -> RGB565, 153 600 bytes             (Ili9341.to_rgb565/1)
        -> the screen                        (Ili9341.write_frame/2)

  Emerge opens no window here. `EmergeSkia.render_to_pixels/2` is its raster part:
  it lays the tree out, draws it to a surface in memory, and gives the bytes back.
  A display server is therefore not necessary, and the firmware ships none.

  ## What it does not do yet

  It takes the `:player` topic only. The `:view` and `:hint` topics need
  `MyHiFi.DeviceUi`, which is not written, so this screen shows the now playing view
  and holds no list. It publishes nothing, because the STMPE610 touch controller
  needs the second chip select line of this bus and that work comes next.

  ## Why it drops events

  `Player.Progress` arrives one time each second, and a frame takes the time to draw
  plus the time to write. If a frame is still going out when the next event arrives,
  a second draw would queue behind the first and the screen would fall further
  behind for as long as the music plays. This module therefore draws the newest view
  and lets the older one go: the state holds the view, and a draw uses whatever the
  view holds when it runs. Section 5.5 of the specification allows this, and it says
  that a slow screen may drop what it cannot draw in time.
  """

  @behaviour MyHiFi.Peripheral

  alias MyHiFi.Artwork
  alias MyHiFi.Event.Player
  alias MyHiFi.Peripheral.PiTft.{Ili9341, Screen}

  @doc """
  Take hold of the screen and draw the first frame.

  Every option goes to `MyHiFi.Peripheral.PiTft.Ili9341.open/1`.
  """
  @impl MyHiFi.Peripheral
  def init(opts) do
    with {:ok, screen} <- Ili9341.open(opts) do
      draw(%{screen: screen, view: Screen.new()})
    end
  end

  @doc "The screen reads what the player does, and it uses no other topic."
  @impl MyHiFi.Peripheral
  def subscriptions, do: [:player]

  @doc false
  @impl MyHiFi.Peripheral
  def handle_event(event, %{view: current} = state) do
    case view(event, current) do
      ^current -> {:ok, state}
      view -> draw(%{state | view: view})
    end
  end

  @doc "Turn the backlight off and give the bus back."
  @impl MyHiFi.Peripheral
  def terminate(_reason, state), do: Ili9341.close(state.screen)

  defp view(%Player.Started{} = event, view) do
    %{
      view
      | state: :playing,
        title: title(event.track),
        subtitle: subtitle(event.track),
        message: nil,
        artwork_path: artwork_disk_path(event.artwork_path),
        live?: event.live?,
        position_ms: event.position_ms,
        duration_ms: duration(event.track)
    }
  end

  defp view(%Player.Progress{} = event, view) do
    %{view | position_ms: event.position_ms, duration_ms: event.duration_ms}
  end

  defp view(%Player.MetadataChanged{} = event, view) do
    %{
      view
      | title: event.title || view.title,
        subtitle: event.artist || view.subtitle,
        artwork_path: artwork_disk_path(event.artwork_path) || view.artwork_path
    }
  end

  defp view(%Player.Buffering{} = event, view),
    do: %{view | state: :buffering, percent: event.percent}

  defp view(%Player.Paused{} = event, view),
    do: %{view | state: :paused, position_ms: event.position_ms}

  defp view(%Player.Failed{} = event, view),
    do: %{view | state: :failed, message: message(event.reason)}

  defp view(%Player.Stopped{}, _view), do: Screen.new()
  defp view(%Player.Standby{entered?: true}, _view), do: Screen.new()

  # A hint, a view event, or a standby that ends changes nothing that this screen
  # shows. An ignored event is normal. See `MyHiFi.Peripheral`.
  defp view(_event, view), do: view

  defp draw(state) do
    {width, height} = Screen.size()

    pixels =
      state.view
      |> Screen.render()
      |> EmergeSkia.render_to_pixels(
        otp_app: :my_hi_fi,
        width: width,
        height: height,
        assets: [
          runtime_paths: [
            enabled: true,
            allowlist: [MyHiFi.Cache.directory()]
          ]
        ]
      )
      |> Ili9341.to_rgb565()

    case Ili9341.write_frame(state.screen, pixels) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  # The event carries the artwork as a URL path like `/artwork/<hash>`. The screen
  # needs the disk path of the thumbnail, so this extracts the hash and looks it up.
  defp artwork_disk_path(nil), do: nil

  defp artwork_disk_path("/artwork/" <> name) do
    case Artwork.serve_thumbnail(name) do
      {:ok, path, _content_type} -> path
      :error -> nil
    end
  end

  defp artwork_disk_path(_url), do: nil

  # A track holds a title, a subtitle and a duration. A source that gives less is
  # normal, and the screen then shows less.
  defp title(%{title: title}), do: title
  defp title(_track), do: nil

  defp subtitle(%{subtitle: subtitle}), do: subtitle
  defp subtitle(_track), do: nil

  # The duration comes from the track when the source knows it, so the bar appears
  # with the title. A live stream holds none, and the first `Progress` gives none
  # either, so the screen shows the time from the start and no bar.
  defp duration(%{duration_ms: duration_ms}), do: duration_ms
  defp duration(_track), do: nil

  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: inspect(reason)
end
