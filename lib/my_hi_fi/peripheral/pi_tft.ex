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

  It takes the `:player` topic only. The `:view` and `:hint` topics need more of
  `MyHiFi.DeviceUi` than is written, so this screen shows the now playing view and
  draws no list. It publishes the four buttons of the board, and it publishes no
  touch: the STMPE610 owns the panel as well as the light, and reading the panel is
  the work that comes next.

  ## Standby

  A screen that stayed lit would tell a person that the device is awake. Standby
  therefore turns the backlight off and puts the panel to sleep, and leaving standby
  wakes the panel, draws the view, and turns the backlight on. The order matters: a
  backlight that came on before the draw would show the frame that the panel held
  before.

  **The light is on the touch controller, and not on a pin of the Raspberry Pi.** A
  panel that sleeps under a light that stays on shows white, which is what this board
  did while the firmware wrote to pin 18. See `MyHiFi.Peripheral.PiTft.Stmpe610`.

  **Standby keeps the view, and it does not clear it.** A person who paused a track
  and then pressed standby gets no event on the way back, because the player leaves
  that track paused. A view that this cleared would show the name of the device and
  not the track that waits.

  A panel that sleeps draws nothing, so an event that arrives in standby moves the
  view and writes no byte to the bus.

  ## Why it drops events

  `Player.Progress` arrives one time each second, and a frame takes the time to draw
  plus the time to write. If a frame is still going out when the next event arrives,
  a second draw would queue behind the first and the screen would fall further
  behind for as long as the music plays. This module therefore draws the newest view
  and lets the older one go: the state keeps the view, and a draw uses whatever the
  view says when it runs. Section 5.5 of the specification allows this, and it says
  that a slow screen may drop what it cannot draw in time.
  """

  @behaviour MyHiFi.Peripheral

  alias MyHiFi.Artwork
  alias MyHiFi.Artwork.Accent
  alias MyHiFi.Device
  alias MyHiFi.Device.Identity
  alias MyHiFi.Event
  alias MyHiFi.Event.Device, as: DeviceEvents
  alias MyHiFi.Event.Input
  alias MyHiFi.Event.Player
  alias MyHiFi.Peripheral.Battery
  alias MyHiFi.Peripheral.Buttons
  alias MyHiFi.Peripheral.PiTft.{Ili9341, Screen, Stmpe610}
  alias MyHiFi.Playback
  alias MyHiFi.Screen.Network

  # How long the level stays on the glass after a person stops moving it. Long enough
  # to read the number, and short enough that the track comes back before they look
  # for it.
  @volume_ms :timer.seconds(3)

  @doc "The name that the settings page draws."
  @impl MyHiFi.Peripheral
  def title, do: "PiTFT 2.8 inch screen"

  @doc """
  Take hold of the screen and the touch controller, and draw the first frame.

  Every option goes to `MyHiFi.Peripheral.PiTft.Ili9341.open/1`. The touch
  controller takes the defaults of `MyHiFi.Peripheral.PiTft.Stmpe610.open/1`, and it
  drives the backlight of this board.
  """
  @impl MyHiFi.Peripheral
  def init(opts) do
    with {:ok, screen} <- Ili9341.open(opts),
         {:ok, stmpe} <- Stmpe610.open(),
         {:ok, buttons} <- Buttons.open() do
      first_frame(%{
        screen: screen,
        stmpe: stmpe,
        buttons: buttons,
        volume_ms: Keyword.get(opts, :volume_ms, @volume_ms),
        view: Screen.new() |> with_battery() |> with_identity() |> with_network(),
        awake?: true
      })
    end
  end

  # **An event says that the charge moved, and this screen may start long after the last
  # one.** The gauge reports a change once a minute at most, so a screen that waited for
  # an event would draw no battery for a minute or for an hour. See
  # `MyHiFi.Peripheral.Battery.last_reading/0`.
  defp with_battery(view) do
    case Battery.last_reading() do
      nil -> view
      reading -> %{view | battery_percent: reading.percent, low_battery?: reading.low?}
    end
  end

  # **A person names the device and gives it a picture at any time, and a screen may
  # start long after that.** An event says that one of the two moved, so a screen that
  # waited for an event would show the name that no person chose. See
  # `MyHiFi.Device.Identity`.
  defp with_identity(view) do
    %{view | device_name: Identity.name(), splash_path: splash(Identity.splash_path())}
  end

  # **`MyHiFi.Device.Monitor` publishes when an interface moves, and a screen may start
  # long after the last one moved.** A screen that waited for an event would say nothing
  # about a router that went off before the board booted.
  defp with_network(view) do
    %{view | network: Network.connection(Device.network!())}
  end

  # **A device that a person gave no picture draws the one that the firmware ships.**
  # `MyHiFi.Device.Identity.shipped_splash/1` names a file for each size of screen, so
  # this screen names its own size and needs no knowledge of what the file is.
  defp splash(address) do
    artwork_disk_path(address) || Identity.shipped_splash(Screen.size())
  end

  # A person can turn the screen on while the device is in standby, and a device that
  # lost its power in standby comes back in standby. The player keeps that state and it
  # publishes no event for a state that did not change, so this asks one time. A page
  # does the same when a person opens it.
  defp first_frame(state) do
    if Playback.state!().standby?, do: doze(state), else: draw(state)
  end

  @doc """
  The screen reads what the player does, and what the hardware does.

  The `:device` topic carries `MyHiFi.Event.Device.BatteryChanged`. A device on the mains
  publishes none of those and this screen then draws no battery, which is the whole of
  what it needs to know. See `MyHiFi.Peripheral.Battery`.

  It also carries `MyHiFi.Event.Device.IdentityChanged`, so a person who names the
  device on the web page reads that name on the screen at once.
  """
  @impl MyHiFi.Peripheral
  def subscriptions, do: [:player, :device]

  @doc false
  @impl MyHiFi.Peripheral
  def handle_event(%Player.Standby{entered?: true}, state), do: doze(state)

  def handle_event(%Player.Standby{entered?: false}, state), do: wake(state)

  # The level goes away by itself, so this schedules the message that takes it away.
  # A person who is still moving it schedules a later one, and the last one decides.
  def handle_event(%Player.VolumeChanged{enabled?: true, supported?: true} = event, state) do
    Process.send_after(self(), :clear_volume, state.volume_ms)

    handle_event(event, state, :drawing)
  end

  def handle_event(event, state), do: handle_event(event, state, :drawing)

  defp handle_event(event, %{view: current} = state, :drawing) do
    case view(event, current) do
      ^current -> {:ok, state}
      view -> draw(%{state | view: view})
    end
  end

  @doc """
  Say that a person pressed a button.

  The lines of the buttons send a message for each change of level, and this turns a
  press into `MyHiFi.Event.Input.ButtonPressed`. **This module says which button and
  not what the button does.** `MyHiFi.DeviceUi` decides that.
  """
  @impl MyHiFi.Peripheral
  def handle_info(:clear_volume, %{view: %{volume_percent: nil}} = state), do: {:ok, state}

  def handle_info(:clear_volume, state) do
    draw(%{state | view: %{state.view | volume_percent: nil}})
  end

  def handle_info(message, state) do
    case Buttons.press(state.buttons, message) do
      {:ok, button, hold, buttons} ->
        Event.publish(:input, %Input.ButtonPressed{
          peripheral: __MODULE__,
          button: button,
          hold: hold
        })

        {:ok, %{state | buttons: buttons}}

      {:none, buttons} ->
        {:ok, %{state | buttons: buttons}}
    end
  end

  @doc "Turn the backlight off and give the hardware back."
  @impl MyHiFi.Peripheral
  def terminate(_reason, state) do
    Buttons.close(state.buttons)
    Stmpe610.close(state.stmpe)
    Ili9341.close(state.screen)
  end

  @doc """
  What Emerge may read from the disk while it draws.

  The cache keeps the thumbnails, and `MyHiFi.Artwork` names each one
  `<hash>.thumbnail`, because a name of the cache carries no type.

  **Emerge refuses a runtime path by its extension, and it reads no byte to decide.**
  The default list names `.jpg` and six other types, so it refused every thumbnail,
  and the screen showed the mark that Emerge draws for a picture that it cannot read.
  Skia reads the bytes and finds the JPEG, so the name of the file is all that this
  changes.

  One extension is also tighter than seven: a runtime path of this firmware is a
  thumbnail of the cache and nothing else.
  """
  @spec asset_options() :: keyword()
  def asset_options do
    [
      runtime_paths: [
        enabled: true,
        allowlist: [MyHiFi.Cache.directory(), Identity.splash_directory()],
        extensions: [".thumbnail", ".png"]
      ]
    ]
  end

  defp view(%Player.Started{} = event, view) do
    %{
      view
      | state: :playing,
        title: title(event.track),
        subtitle: subtitle(event.track),
        message: nil,
        artwork_path: artwork_disk_path(event.artwork_path),
        accent: accent(event.artwork_path),
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
        artwork_path: artwork_disk_path(event.artwork_path) || view.artwork_path,
        accent: accent(event.artwork_path) || view.accent
    }
  end

  defp view(%DeviceEvents.BatteryChanged{} = event, view),
    do: %{view | battery_percent: event.percent, low_battery?: event.low?}

  defp view(%DeviceEvents.IdentityChanged{} = event, view),
    do: %{view | device_name: event.name, splash_path: splash(event.splash_path)}

  # A router that goes off is the reason that the music stopped, and a person reading a
  # screen that said nothing would look at the device instead. See
  # `MyHiFi.Screen.Network`.
  defp view(%DeviceEvents.NetworkChanged{interfaces: interfaces}, view),
    do: %{view | network: Network.connection(interfaces)}

  # **A person holding a button needs to see the number that they are setting.** A level
  # that the card cannot set, and a control that a person has not turned on, both draw
  # nothing: there is nothing for the person to move.
  defp view(%Player.VolumeChanged{enabled?: true, supported?: true} = event, view),
    do: %{view | volume_percent: event.percent}

  defp view(%Player.VolumeChanged{}, view), do: view

  defp view(%Player.Buffering{} = event, view),
    do: %{view | state: :buffering, percent: event.percent}

  defp view(%Player.Paused{} = event, view),
    do: %{view | state: :paused, position_ms: event.position_ms}

  defp view(%Player.Failed{} = event, view),
    do: %{view | state: :failed, message: message(event.reason)}

  # A stop clears the track, and it clears neither the cell nor the name of the device.
  defp view(%Player.Stopped{}, view), do: Screen.stopped(view)

  # A hint or a view event changes nothing that this screen shows. An ignored event is
  # normal. See `MyHiFi.Peripheral`.
  defp view(_event, view), do: view

  # Standby keeps the view. A person who paused a track and pressed standby gets no
  # event on the way back, because the player leaves that track paused, so a view that
  # this cleared would show the name of the device and not the track that waits.
  defp doze(%{awake?: false} = state), do: {:ok, state}

  defp doze(state) do
    with :ok <- Stmpe610.backlight(state.stmpe, false),
         :ok <- Ili9341.display(state.screen, false) do
      {:ok, %{state | awake?: false}}
    end
  end

  defp wake(%{awake?: true} = state), do: {:ok, state}

  defp wake(state) do
    with :ok <- Ili9341.display(state.screen, true),
         {:ok, state} <- draw(%{state | awake?: true}),
         :ok <- Stmpe610.backlight(state.stmpe, true) do
      {:ok, state}
    end
  end

  # A panel that sleeps draws nothing, so a `Progress` event in standby moves the view
  # and writes no byte to the bus.
  defp draw(%{awake?: false} = state), do: {:ok, state}

  defp draw(state) do
    {width, height} = Screen.size()

    pixels =
      state.view
      |> Screen.render()
      |> EmergeSkia.render_to_pixels(
        otp_app: :my_hi_fi,
        width: width,
        height: height,
        assets: asset_options()
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
      {:ok, path, _content_type, _etag} -> path
      :error -> nil
    end
  end

  defp artwork_disk_path(_url), do: nil

  # The screen draws in red, green and blue, so the colour of the artwork becomes that
  # here and `MyHiFi.Peripheral.PiTft.Screen` needs no knowledge of OKLab.
  defp accent(nil), do: nil

  defp accent("/artwork/" <> name) do
    case Artwork.accent(name) do
      nil -> nil
      colour -> Accent.to_rgb(colour)
    end
  end

  defp accent(_url), do: nil

  # A track has a title, a subtitle and a duration. A source that gives less is
  # normal, and the screen then shows less.
  defp title(%{title: title}), do: title
  defp title(_track), do: nil

  defp subtitle(%{subtitle: subtitle}), do: subtitle
  defp subtitle(_track), do: nil

  # The duration comes from the track when the source knows it, so the bar appears
  # with the title. A live stream has none, and the first `Progress` gives none
  # either, so the screen shows the time from the start and no bar.
  defp duration(%{duration_ms: duration_ms}), do: duration_ms
  defp duration(_track), do: nil

  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: inspect(reason)
end
