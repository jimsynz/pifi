defmodule MyHiFi.Peripheral.PiTftTest do
  # `MyHiFi.Test.RecordingScreen` is a named process, so two of these cannot run at
  # the same time.
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Device.Identity
  alias MyHiFi.Event.Device, as: DeviceEvents
  alias MyHiFi.Event.Player
  alias MyHiFi.Peripheral.PiTft
  alias MyHiFi.Test.RecordingScreen
  alias Nerves.Runtime.KV

  # A JPEG of 16 by 16 pixels that Skia can read. A picture of a few bytes that names
  # itself a JPEG would draw the same mark as a picture that Emerge refuses, and this
  # test would then hold nothing.
  @jpeg Base.decode64!(
          "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABQODxIPDRQSEBIXFRQYHjIhHhwcHj0sLiQySUBMS0dARk" <>
            "VQWnNiUFVtVkVGZIhlbXd7gYKBTmCNl4x9lnN+gXz/2wBDARUXFx4aHjshITt8U0ZTfHx8fHx8fHx8" <>
            "fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHz/wAARCAAQABADASIAAhEBAx" <>
            "EB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAA" <>
            "AAAAAAAAAAAABAb/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCaAMoH/9k="
        )

  @memory_write 0x2C
  @sleep_in 0x10
  @sleep_out 0x11
  @display_off 0x28
  @display_on 0x29

  setup do
    RecordingScreen.use_it()
    {:ok, state} = PiTft.init([])
    RecordingScreen.forget()

    %{state: state}
  end

  test "it draws the first frame while it takes hold of the screen" do
    RecordingScreen.use_it()

    {:ok, _state} = PiTft.init([])

    assert frames() == 1
  end

  test "it starts dark when the device is in standby" do
    :ok = MyHiFi.Player.standby(true)
    on_exit(fn -> MyHiFi.Player.standby(false) end)

    RecordingScreen.use_it()

    {:ok, state} = PiTft.init([])

    refute state.awake?
    assert frames() == 0
    # Taking hold of the backlight writes its level, so the light goes on and then
    # off. It was on from the moment that the board had power, so a person sees no
    # change. See `MyHiFi.Peripheral.PiTft.Stmpe610`.
    assert List.last(RecordingScreen.backlight()) == 0
  end

  # The name lives in `Nerves.Runtime.KV`, and a screen may start long after a person
  # wrote it, so the first frame reads it and waits for no event.
  test "the first frame holds the name that a person gave the device" do
    :ok = Identity.put_name("Kitchen")
    on_exit(fn -> KV.put("myhifi_device_name", "") end)

    RecordingScreen.use_it()

    {:ok, state} = PiTft.init([])

    assert state.view.device_name == "Kitchen"
  end

  # **A device that a person gave no picture draws the mark of the product**, and the
  # file is the size of this screen, so a draw scales nothing.
  test "the first frame holds the picture that this firmware ships" do
    RecordingScreen.use_it()

    {:ok, state} = PiTft.init([])

    assert state.view.splash_path == Identity.shipped_splash(PiTft.Screen.size())
    assert Path.basename(state.view.splash_path) == "pifi-320x240.png"
  end

  test "it reads the player topic and the device topic" do
    assert PiTft.subscriptions() == [:player, :device]
  end

  describe "handle_event/2" do
    test "a start shows the track and how long it runs", %{state: state} do
      {:ok, state} = PiTft.handle_event(started(), state)

      assert state.view.state == :playing
      assert state.view.title == "The Detail"
      assert state.view.subtitle == "RNZ"
      assert state.view.duration_ms == 1_284_000
      assert state.view.position_ms == 30_000
      assert frames() == 1
    end

    test "a start of a live stream holds no duration, so the screen draws no bar", %{state: state} do
      event = %Player.Started{
        source: MyHiFi.Source.InternetRadio,
        track: %{ref: "rnz", title: "RNZ National", subtitle: nil, duration_ms: nil},
        live?: true,
        position_ms: 0
      }

      {:ok, state} = PiTft.handle_event(event, state)

      assert state.view.live?
      assert state.view.duration_ms == nil
    end

    test "progress moves the time", %{state: state} do
      {:ok, state} = PiTft.handle_event(started(), state)
      RecordingScreen.forget()

      {:ok, state} =
        PiTft.handle_event(%Player.Progress{position_ms: 31_000, duration_ms: 1_284_000}, state)

      assert state.view.position_ms == 31_000
      assert frames() == 1
    end

    test "the same progress twice draws one frame, because nothing changed", %{state: state} do
      progress = %Player.Progress{position_ms: 31_000, duration_ms: 1_284_000}

      {:ok, state} = PiTft.handle_event(progress, state)
      RecordingScreen.forget()

      {:ok, _state} = PiTft.handle_event(progress, state)

      assert frames() == 0
    end

    test "a stream that names a new track shows that name", %{state: state} do
      {:ok, state} = PiTft.handle_event(started(), state)

      {:ok, state} =
        PiTft.handle_event(%Player.MetadataChanged{title: "Waiata", artist: "Six60"}, state)

      assert state.view.title == "Waiata"
      assert state.view.subtitle == "Six60"
    end

    test "a stream that names no title keeps the one that it holds", %{state: state} do
      {:ok, state} = PiTft.handle_event(started(), state)

      {:ok, state} = PiTft.handle_event(%Player.MetadataChanged{title: nil, artist: nil}, state)

      assert state.view.title == "The Detail"
      assert state.view.subtitle == "RNZ"
    end

    test "a pause keeps the track in front of the person", %{state: state} do
      {:ok, state} = PiTft.handle_event(started(), state)

      {:ok, state} = PiTft.handle_event(%Player.Paused{position_ms: 44_000}, state)

      assert state.view.state == :paused
      assert state.view.title == "The Detail"
      assert state.view.position_ms == 44_000
    end

    test "a name that a person gave reaches the view", %{state: state} do
      event = %DeviceEvents.IdentityChanged{name: "Kitchen", splash_path: nil}

      {:ok, state} = PiTft.handle_event(event, state)

      assert state.view.device_name == "Kitchen"
    end

    test "a stop keeps the name, because the device did not change", %{state: state} do
      event = %DeviceEvents.IdentityChanged{name: "Kitchen", splash_path: nil}

      {:ok, state} = PiTft.handle_event(event, state)
      {:ok, state} = PiTft.handle_event(%Player.Stopped{reason: :requested}, state)

      assert state.view.state == :stopped
      assert state.view.device_name == "Kitchen"
    end

    test "a stop leaves nothing selected", %{state: state} do
      {:ok, state} = PiTft.handle_event(started(), state)

      {:ok, state} = PiTft.handle_event(%Player.Stopped{reason: :requested}, state)

      assert state.view.state == :stopped
      assert state.view.title == nil
    end

    test "standby turns the backlight off and puts the panel to sleep", %{state: state} do
      {:ok, state} = PiTft.handle_event(started(), state)
      RecordingScreen.forget()

      {:ok, state} = PiTft.handle_event(%Player.Standby{entered?: true}, state)

      refute state.awake?
      assert RecordingScreen.backlight() == [0]
      assert @display_off in sent()
      assert @sleep_in in sent()
      assert frames() == 0
    end

    test "standby holds the track, so a person sees it again on the way back", %{state: state} do
      {:ok, state} = PiTft.handle_event(started(), state)

      {:ok, state} = PiTft.handle_event(%Player.Standby{entered?: true}, state)

      assert state.view.state == :playing
      assert state.view.title == "The Detail"
    end

    test "an event in standby moves the view and writes no byte", %{state: state} do
      {:ok, state} = PiTft.handle_event(%Player.Standby{entered?: true}, state)
      RecordingScreen.forget()

      {:ok, state} =
        PiTft.handle_event(%Player.Progress{position_ms: 4000, duration_ms: 60_000}, state)

      assert state.view.position_ms == 4000
      assert frames() == 0
    end

    test "leaving standby wakes the panel, draws, and lights it after that",
         %{state: state} do
      {:ok, state} = PiTft.handle_event(started(), state)
      {:ok, state} = PiTft.handle_event(%Player.Standby{entered?: true}, state)
      RecordingScreen.forget()

      {:ok, state} = PiTft.handle_event(%Player.Standby{entered?: false}, state)

      assert state.awake?
      assert frames() == 1
      assert RecordingScreen.backlight() == [1]
      assert @sleep_out in sent()
      assert @display_on in sent()
    end

    test "a second standby writes nothing more", %{state: state} do
      {:ok, state} = PiTft.handle_event(%Player.Standby{entered?: true}, state)
      RecordingScreen.forget()

      {:ok, state} = PiTft.handle_event(%Player.Standby{entered?: true}, state)

      refute state.awake?
      assert RecordingScreen.backlight() == []
      assert sent() == []
    end

    test "leaving standby that never began writes nothing", %{state: state} do
      RecordingScreen.forget()

      {:ok, state} = PiTft.handle_event(%Player.Standby{entered?: false}, state)

      assert state.awake?
      assert RecordingScreen.backlight() == []
      assert sent() == []
    end

    test "the charge reaches the view, so the screen can draw it", %{state: state} do
      {:ok, state} =
        PiTft.handle_event(%MyHiFi.Event.Device.BatteryChanged{percent: 64, low?: false}, state)

      assert state.view.battery_percent == 64
      refute state.view.low_battery?
    end

    # A device on the mains publishes none of these, and a battery at 0 would be a lie.
    test "a device that reported no charge draws no battery", %{state: state} do
      assert state.view.battery_percent == nil
    end

    # A stop clears the track, and it does not clear the cell.
    test "a stop keeps the charge", %{state: state} do
      {:ok, state} =
        PiTft.handle_event(%MyHiFi.Event.Device.BatteryChanged{percent: 64, low?: false}, state)

      {:ok, state} = PiTft.handle_event(%Player.Stopped{reason: :requested}, state)

      assert state.view.state == :stopped
      assert state.view.battery_percent == 64
    end

    test "a failure says what went wrong", %{state: state} do
      {:ok, state} = PiTft.handle_event(%Player.Failed{reason: :timeout}, state)

      assert state.view.state == :failed
      assert state.view.message == ":timeout"
    end

    test "buffering counts while the buffer fills", %{state: state} do
      {:ok, state} = PiTft.handle_event(%Player.Buffering{percent: 42}, state)

      assert state.view.state == :buffering
      assert state.view.percent == 42
    end

    test "an event of another topic changes nothing and draws nothing", %{state: state} do
      {:ok, ^state} = PiTft.handle_event(%URI{}, state)

      assert frames() == 0
    end
  end

  test "each frame is the whole screen, in RGB565", %{state: state} do
    {:ok, _state} = PiTft.handle_event(started(), state)

    assert [{@memory_write, pixels}] =
             Enum.filter(RecordingScreen.commands(), &match?({@memory_write, _}, &1))

    {width, height} = PiTft.Ili9341.size()
    assert byte_size(pixels) == width * height * 2
  end

  describe "the pictures that Emerge may read" do
    setup do
      directory = Path.join(MyHiFi.Cache.directory(), "artwork")
      File.mkdir_p!(directory)

      thumbnail = Path.join(directory, "a_picture.thumbnail")
      picture = Path.join(directory, "a_picture.jpg")
      File.write!(thumbnail, @jpeg)
      File.write!(picture, @jpeg)

      on_exit(fn ->
        File.rm(thumbnail)
        File.rm(picture)
      end)

      %{directory: directory, thumbnail: thumbnail, picture: picture}
    end

    # Emerge refuses a runtime path by its extension, and a name of the cache holds
    # none of the seven that Emerge allows by default. The screen then showed the mark
    # that Emerge draws for a picture that it cannot read.
    test "a thumbnail of the cache draws what its bytes hold", context do
      %{directory: directory, thumbnail: thumbnail, picture: picture} = context

      by_extension = [
        runtime_paths: [
          enabled: true,
          allowlist: [MyHiFi.Cache.directory()],
          extensions: [".jpg"]
        ]
      ]

      ours = pixels_of(thumbnail, PiTft.asset_options())
      absent = pixels_of(Path.join(directory, "absent.thumbnail"), PiTft.asset_options())

      assert ours == pixels_of(picture, by_extension)
      refute ours == absent
    end
  end

  defp pixels_of(path, assets) do
    {width, height} = PiTft.Screen.size()

    %{PiTft.Screen.new() | state: :playing, title: "RNZ National", artwork_path: path}
    |> PiTft.Screen.render()
    |> EmergeSkia.render_to_pixels(
      otp_app: :my_hi_fi,
      width: width,
      height: height,
      assets: assets
    )
  end

  # **A person holding a button needs to see the number that they are setting**, and the
  # level goes away by itself so that the progress bar comes back.
  describe "the level of the output" do
    test "a level that moves goes on the glass and then goes away", %{state: state} do
      {:ok, state} = PiTft.handle_event(started(), state)
      RecordingScreen.forget()

      {:ok, state} = PiTft.handle_event(volume(40), state)

      assert state.view.volume_percent == 40
      assert frames() == 1

      {:ok, state} = PiTft.handle_info(:clear_volume, state)

      assert state.view.volume_percent == nil
      assert frames() == 2
    end

    test "a message that arrives twice draws one frame", %{state: state} do
      {:ok, state} = PiTft.handle_event(volume(40), state)
      {:ok, state} = PiTft.handle_info(:clear_volume, state)
      RecordingScreen.forget()

      {:ok, ^state} = PiTft.handle_info(:clear_volume, state)

      assert frames() == 0
    end

    test "a level that nothing can set draws nothing", %{state: state} do
      RecordingScreen.forget()

      {:ok, ^state} =
        PiTft.handle_event(
          %Player.VolumeChanged{percent: 40, enabled?: true, supported?: false},
          state
        )

      assert frames() == 0
    end

    defp volume(percent),
      do: %Player.VolumeChanged{percent: percent, enabled?: true, supported?: true}
  end

  # A router that goes off is the reason that the music stopped, and a person reading a
  # screen that said nothing would look at the device instead.
  describe "the network" do
    test "a router that goes off reaches the screen", %{state: state} do
      {:ok, state} = PiTft.handle_event(started(), state)
      RecordingScreen.forget()

      {:ok, state} = PiTft.handle_event(net_down(), state)

      assert state.view.network == :disconnected
      assert frames() == 1
    end

    test "a network that comes back takes the warning away", %{state: state} do
      {:ok, state} = PiTft.handle_event(net_down(), state)
      {:ok, state} = PiTft.handle_event(net_up(), state)

      assert state.view.network == :internet
    end

    # A device that reaches its router and nothing past it plays nothing, and a person
    # reads that state as working. See `MyHiFi.Screen.Network`.
    test "a device with no way out of its network says so", %{state: state} do
      {:ok, state} =
        PiTft.handle_event(%DeviceEvents.NetworkChanged{interfaces: [%{connection: :lan}]}, state)

      assert state.view.network == :lan
    end

    # A stop clears the track, and the network belongs to the hardware.
    test "a stop keeps what the network says", %{state: state} do
      {:ok, state} = PiTft.handle_event(net_down(), state)
      {:ok, state} = PiTft.handle_event(%Player.Stopped{reason: :requested}, state)

      assert state.view.network == :disconnected
    end

    # VintageNet publishes for each address that an interface takes, and a second event
    # that says the same thing must not cost a frame.
    test "an event that changes nothing draws nothing", %{state: state} do
      {:ok, state} = PiTft.handle_event(net_down(), state)
      RecordingScreen.forget()

      {:ok, ^state} = PiTft.handle_event(net_down(), state)

      assert frames() == 0
    end

    defp net_down, do: %DeviceEvents.NetworkChanged{interfaces: [%{connection: :disconnected}]}
    defp net_up, do: %DeviceEvents.NetworkChanged{interfaces: [%{connection: :internet}]}
  end

  defp started do
    %Player.Started{
      source: MyHiFi.Source.Podcasts,
      track: %{
        ref: "detail",
        title: "The Detail",
        subtitle: "RNZ",
        duration_ms: 1_284_000
      },
      live?: false,
      position_ms: 30_000
    }
  end

  defp frames do
    RecordingScreen.commands()
    |> Enum.count(&match?({@memory_write, _pixels}, &1))
  end

  # The command bytes that reached the screen, so a test names one and asks whether the
  # driver sent it.
  defp sent, do: Enum.map(RecordingScreen.commands(), fn {command, _payload} -> command end)
end
