defmodule MyHiFi.Peripheral.PirateAudio do
  @moduledoc """
  The screen of the Pimoroni Pirate Audio.

  It takes the events of the `:player` topic, keeps what they say in a
  `t:MyHiFi.Peripheral.PirateAudio.Screen.view/0`, draws that view with Emerge, and
  writes the pixels to the ST7789 over SPI.

      Player event
        -> the view                          (this module)
        -> Emerge tree                       (MyHiFi.Peripheral.PirateAudio.Screen)
        -> RGBA, 230 400 bytes               (EmergeSkia.render_to_pixels/2)
        -> RGB565, 115 200 bytes             (St7789.to_rgb565/1)
        -> the screen                        (St7789.write_frame/2)

  The DAC of this board is not part of this peripheral, and it needs no code at all.
  It answers to the `hifiberry-dac` profile of `MyHiFi.Hardware`, which writes the
  overlay into `config.txt`, and `MyHiFi.Output.Alsa` then lists it as a card.

  ## Two buttons hold three controls

  A tap of the first plays or pauses, a hold of it reaches standby, and a tap of the
  second plays the track after this one. `MyHiFi.DeviceUi` decides all three, and this
  module says which button and how long a person held it.

  ## Two buttons, and not four

  The board holds four, at GPIO 5, 6, 16 and 24, one at each corner of the screen. **Two
  of them work on this board and the other two are broken**, so this reads 5 and 6 alone.

  A measurement on 2026-09-02 found that. Twelve free lines held an interrupt, a person
  pressed the three buttons that they believed worked, twice, and only 5 and 6 ever
  answered: `[5, 6, 6, 6, 6, 5, 6]`, where a line that repeats is the bounce that
  `MyHiFi.Peripheral.Buttons` takes away. GPIO 16 opened and armed with the rest and
  never went low.

  `:lines` names them, so a board whose four all work needs no change here.

  ## It ignores the progress of a track

  `Player.Progress` arrives one time each second, and this screen draws no bar, so a
  draw for it would decode a JPEG and scale it to 240 by 240 for a picture that did not
  change. The view therefore holds no position and no duration, and the event moves
  nothing. See `MyHiFi.Peripheral.PirateAudio.Screen`.

  ## A cell that is nearly flat

  The screen says `LOW BATTERY CHARGE NOW` over a rose band, and it says it over the
  track, the artwork and every other state. This device holds no way to turn its own
  power off, so charging it is the one thing that a person can do about a flat cell, and
  a title beside that warning would hide it.

  `MyHiFi.AutoStandby` puts the device in standby at the same moment, so this is what a
  person reads when they wake it. See `MyHiFi.Peripheral.Battery`.

  ## Standby

  A screen that stayed lit would tell a person that the device is awake. Standby turns
  the backlight off and puts the panel to sleep, and leaving standby wakes the panel,
  draws the view, and turns the backlight on.

  **The order matters in both directions.** A backlight that came on before the draw
  would show the frame that the panel held before. A panel that sleeps under a light
  that is on shows white, so the light goes off first.

  **Standby holds the view, and it does not clear it.** A person who paused a track and
  then pressed standby gets no event on the way back, because the player leaves that
  track paused. A view that this cleared would show the name of the device and not the
  track that waits.

  A panel that sleeps draws nothing, so an event that arrives in standby moves the view
  and writes no byte to the bus.
  """

  @behaviour MyHiFi.Peripheral

  alias MyHiFi.Artwork
  alias MyHiFi.Event
  alias MyHiFi.Event.Device, as: DeviceEvents
  alias MyHiFi.Event.Input
  alias MyHiFi.Event.Player
  alias MyHiFi.Peripheral.Battery
  alias MyHiFi.Peripheral.Buttons
  alias MyHiFi.Peripheral.PirateAudio.{Screen, St7789}
  alias MyHiFi.Playback

  # The two buttons that answer on this board, in the order that they sit down the left
  # of the screen. See the moduledoc for the measurement that found them.
  @lines [5, 6]

  # **Two buttons hold three controls, so one of them holds two.** A person who holds the
  # first button for this long asks for standby, and a tap of it plays or pauses. See
  # `MyHiFi.DeviceUi` for what each one means, and `MyHiFi.Peripheral.Buttons` for why a
  # tap still answers at once.
  @hold_ms 600

  @doc "The name that the settings page draws."
  @impl MyHiFi.Peripheral
  def title, do: "Pirate Audio 1.3 inch screen"

  @doc """
  Take hold of the screen and draw the first frame.

  Every option goes to `MyHiFi.Peripheral.PirateAudio.St7789.open/1`. The backlight
  stays off until the first frame is on the glass.
  """
  @impl MyHiFi.Peripheral
  def init(opts) do
    with {:ok, screen} <- St7789.open(opts),
         {:ok, buttons} <-
           Buttons.open(
             lines: Keyword.get(opts, :lines, @lines),
             hold_ms: Keyword.get(opts, :hold_ms, @hold_ms)
           ) do
      first_frame(%{
        screen: screen,
        buttons: buttons,
        view: with_battery(Screen.new()),
        awake?: true
      })
    end
  end

  # **An event says that the charge moved, and this screen may start long after the last
  # one.** See `MyHiFi.Peripheral.Battery.last_reading/0`.
  defp with_battery(view) do
    case Battery.last_reading() do
      nil -> view
      reading -> %{view | battery_percent: reading.percent, low_battery?: reading.low?}
    end
  end

  # A person can turn the screen on while the device is in standby, and a device that
  # lost its power in standby comes back in standby. The player holds that state and it
  # publishes no event for a state that did not change, so this asks one time.
  defp first_frame(state) do
    if Playback.state!().standby? do
      {:ok, %{state | awake?: false}}
    else
      wake(%{state | awake?: false})
    end
  end

  @doc """
  The screen reads what the player does, and what the hardware does.

  The `:device` topic carries `MyHiFi.Event.Device.BatteryChanged`, and a cell that is
  nearly flat is the one thing that this screen says over the top of everything else.
  """
  @impl MyHiFi.Peripheral
  def subscriptions, do: [:player, :device]

  @doc false
  @impl MyHiFi.Peripheral
  def handle_event(%Player.Standby{entered?: true}, state), do: doze(state)

  def handle_event(%Player.Standby{entered?: false}, state), do: wake(state)

  def handle_event(event, %{view: current} = state) do
    case view(event, current) do
      ^current -> {:ok, state}
      view -> draw(%{state | view: view})
    end
  end

  @doc """
  Say that a person pressed a button.

  **This module says which button and not what the button does.** `MyHiFi.DeviceUi`
  holds that, because a pad of two and a row of four do not mean the same thing.
  """
  @impl MyHiFi.Peripheral
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
    St7789.close(state.screen)
  end

  @doc """
  What Emerge may read from the disk while it draws.

  The cache holds the thumbnails, and `MyHiFi.Artwork` names each one
  `<hash>.thumbnail`, because a name of the cache carries no type. Emerge refuses a
  runtime path by its extension and reads no byte to decide, and its default list holds
  `.jpg` and six other names, so it would refuse every thumbnail and draw the mark that
  it draws for a picture it cannot read.
  """
  @spec asset_options() :: keyword()
  def asset_options do
    [
      runtime_paths: [
        enabled: true,
        allowlist: [MyHiFi.Cache.directory()],
        extensions: [".thumbnail"]
      ]
    ]
  end

  defp view(%Player.Started{} = event, view) do
    %{
      view
      | state: :playing,
        title: track_title(event.track),
        subtitle: track_subtitle(event.track),
        message: nil,
        artwork_path: artwork_disk_path(event.artwork_path)
    }
  end

  defp view(%Player.MetadataChanged{} = event, view) do
    %{
      view
      | title: event.title || view.title,
        subtitle: event.artist || view.subtitle,
        artwork_path: artwork_disk_path(event.artwork_path) || view.artwork_path
    }
  end

  # This device cannot turn its own power off, so the warning stays in front of a person
  # until they charge it. `MyHiFi.AutoStandby` puts the device in standby at the same
  # moment, so a person reads this when they wake it.
  defp view(%DeviceEvents.BatteryChanged{} = event, view),
    do: %{view | battery_percent: event.percent, low_battery?: event.low?}

  defp view(%Player.Buffering{}, view), do: %{view | state: :buffering}

  defp view(%Player.Paused{}, view), do: %{view | state: :paused}

  defp view(%Player.Failed{} = event, view),
    do: %{view | state: :failed, message: message(event.reason)}

  # A stop clears the track, and it does not clear the cell. The warning belongs to the
  # hardware, so only the gauge takes it away.
  defp view(%Player.Stopped{}, view) do
    %{Screen.new() | battery_percent: view.battery_percent, low_battery?: view.low_battery?}
  end

  # `Player.Progress` lands here, and so do the other events of the `:device` topic. An
  # ignored event is normal. See `MyHiFi.Peripheral`.
  defp view(_event, view), do: view

  defp doze(%{awake?: false} = state), do: {:ok, state}

  defp doze(state) do
    with :ok <- St7789.backlight(state.screen, false),
         :ok <- St7789.display(state.screen, false) do
      {:ok, %{state | awake?: false}}
    end
  end

  defp wake(%{awake?: true} = state), do: {:ok, state}

  defp wake(state) do
    with :ok <- St7789.display(state.screen, true),
         {:ok, state} <- draw(%{state | awake?: true}),
         :ok <- St7789.backlight(state.screen, true) do
      {:ok, state}
    end
  end

  # A panel that sleeps draws nothing, so an event in standby moves the view and writes
  # no byte to the bus.
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
      |> St7789.to_rgb565()

    case St7789.write_frame(state.screen, pixels) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  # The event carries the artwork as a URL path like `/artwork/<hash>`. The screen needs
  # the disk path of the thumbnail, so this extracts the hash and looks it up.
  defp artwork_disk_path(nil), do: nil

  defp artwork_disk_path("/artwork/" <> name) do
    case Artwork.serve_thumbnail(name) do
      {:ok, path, _content_type, _etag} -> path
      :error -> nil
    end
  end

  defp artwork_disk_path(_url), do: nil

  # A track holds a title and a subtitle. A source that gives less is normal, and the
  # screen then shows less.
  defp track_title(%{title: title}), do: title
  defp track_title(_track), do: nil

  defp track_subtitle(%{subtitle: subtitle}), do: subtitle
  defp track_subtitle(_track), do: nil

  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: inspect(reason)
end
