defmodule MyHiFi.Peripheral.PirateAudioTest do
  # `MyHiFi.Test.RecordingScreen` is a named process, so two of these cannot run at the
  # same time.
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Device.Identity
  alias MyHiFi.Event.Device, as: DeviceEvents
  alias MyHiFi.Event.Player
  alias MyHiFi.Peripheral.PirateAudio
  alias MyHiFi.Peripheral.PirateAudio.Screen
  alias MyHiFi.Test.RecordingScreen
  alias Nerves.Runtime.KV

  @memory_write 0x2C
  @sleep_in 0x10
  @sleep_out 0x11
  @display_off 0x28
  @display_on 0x29

  @board [screen_bus: "spidev0.1", data_command: 9, backlight_line: 13]

  setup do
    RecordingScreen.use_it(@board)
    {:ok, state} = PirateAudio.init([])
    RecordingScreen.forget()

    %{state: state}
  end

  test "it draws the first frame and lights the screen after that" do
    RecordingScreen.use_it(@board)

    {:ok, state} = PirateAudio.init([])

    assert state.awake?
    assert frames() == 1
    assert List.last(RecordingScreen.backlight_line()) == 1
  end

  test "it starts dark when the device is in standby" do
    :ok = MyHiFi.Player.standby(true)
    on_exit(fn -> MyHiFi.Player.standby(false) end)

    RecordingScreen.use_it(@board)

    {:ok, state} = PirateAudio.init([])

    refute state.awake?
    assert frames() == 0
    refute 1 in RecordingScreen.backlight_line()
  end

  # The name lives in `Nerves.Runtime.KV`, and a screen may start long after a person
  # wrote it, so the first frame reads it and waits for no event.
  test "the first frame holds the name that a person gave the device" do
    :ok = Identity.put_name("Kitchen")
    on_exit(fn -> KV.put("myhifi_device_name", "") end)

    RecordingScreen.use_it(@board)

    {:ok, state} = PirateAudio.init([])

    assert state.view.device_name == "Kitchen"
  end

  test "it reads the player topic and the device topic" do
    assert PirateAudio.subscriptions() == [:player, :device]
  end

  describe "handle_event/2" do
    test "a start shows the track", %{state: state} do
      {:ok, state} = PirateAudio.handle_event(started(), state)

      assert state.view.state == :playing
      assert state.view.title == "The Detail"
      assert state.view.subtitle == "RNZ"
      assert frames() == 1
    end

    # This screen draws no bar, so a draw for progress would decode a JPEG and scale it
    # for a picture that did not change. See `MyHiFi.Peripheral.PirateAudio`.
    test "progress changes nothing and draws nothing", %{state: state} do
      {:ok, state} = PirateAudio.handle_event(started(), state)
      RecordingScreen.forget()

      {:ok, ^state} =
        PirateAudio.handle_event(
          %Player.Progress{position_ms: 31_000, duration_ms: 1_284_000},
          state
        )

      assert frames() == 0
    end

    test "a stream that names a new track shows that name", %{state: state} do
      {:ok, state} = PirateAudio.handle_event(started(), state)

      {:ok, state} =
        PirateAudio.handle_event(%Player.MetadataChanged{title: "Waiata", artist: "Six60"}, state)

      assert state.view.title == "Waiata"
      assert state.view.subtitle == "Six60"
    end

    test "a stream that names no title keeps the one that it holds", %{state: state} do
      {:ok, state} = PirateAudio.handle_event(started(), state)

      {:ok, state} =
        PirateAudio.handle_event(%Player.MetadataChanged{title: nil, artist: nil}, state)

      assert state.view.title == "The Detail"
      assert state.view.subtitle == "RNZ"
    end

    test "a pause keeps the track in front of the person", %{state: state} do
      {:ok, state} = PirateAudio.handle_event(started(), state)

      {:ok, state} = PirateAudio.handle_event(%Player.Paused{position_ms: 44_000}, state)

      assert state.view.state == :paused
      assert state.view.title == "The Detail"
    end

    test "a stop leaves nothing selected", %{state: state} do
      {:ok, state} = PirateAudio.handle_event(started(), state)

      {:ok, state} = PirateAudio.handle_event(%Player.Stopped{reason: :requested}, state)

      assert state.view.state == :stopped
      assert state.view.title == nil
    end

    test "a name that a person gave reaches the view", %{state: state} do
      event = %DeviceEvents.IdentityChanged{name: "Kitchen", splash_path: nil}

      {:ok, state} = PirateAudio.handle_event(event, state)

      assert state.view.device_name == "Kitchen"
    end

    test "a stop keeps the name, because the device did not change", %{state: state} do
      event = %DeviceEvents.IdentityChanged{name: "Kitchen", splash_path: nil}

      {:ok, state} = PirateAudio.handle_event(event, state)
      {:ok, state} = PirateAudio.handle_event(%Player.Stopped{reason: :requested}, state)

      assert state.view.state == :stopped
      assert state.view.device_name == "Kitchen"
    end

    test "a failure says what went wrong", %{state: state} do
      {:ok, state} = PirateAudio.handle_event(%Player.Failed{reason: :timeout}, state)

      assert state.view.state == :failed
      assert state.view.message == ":timeout"
    end

    # This device cannot turn its own power off, so charging it is the one thing that a
    # person can do about a flat cell, and a track title beside that would hide it.
    test "a cell that is nearly flat shows the warning over everything else", %{state: state} do
      {:ok, state} = PirateAudio.handle_event(started(), state)
      RecordingScreen.forget()

      {:ok, state} =
        PirateAudio.handle_event(%DeviceEvents.BatteryChanged{percent: 20, low?: true}, state)

      assert state.view.low_battery?
      assert Screen.headline(state.view) == "LOW BATTERY\nCHARGE NOW"
      assert frames() == 1
    end

    test "a cell that is charged again gives the track back", %{state: state} do
      {:ok, state} = PirateAudio.handle_event(started(), state)

      {:ok, state} =
        PirateAudio.handle_event(%DeviceEvents.BatteryChanged{percent: 20, low?: true}, state)

      {:ok, state} =
        PirateAudio.handle_event(%DeviceEvents.BatteryChanged{percent: 80, low?: false}, state)

      refute state.view.low_battery?
      assert Screen.headline(state.view) == "The Detail"
    end

    # A stop clears the track, and it does not clear the cell.
    test "a stop keeps the warning, because the cell did not change", %{state: state} do
      {:ok, state} =
        PirateAudio.handle_event(%DeviceEvents.BatteryChanged{percent: 20, low?: true}, state)

      {:ok, state} = PirateAudio.handle_event(%Player.Stopped{reason: :requested}, state)

      assert state.view.state == :stopped
      assert state.view.low_battery?
    end

    test "the charge reaches the view, so the screen can draw it", %{state: state} do
      {:ok, state} =
        PirateAudio.handle_event(%DeviceEvents.BatteryChanged{percent: 64, low?: false}, state)

      assert state.view.battery_percent == 64
      refute state.view.low_battery?
    end

    # A device on the mains publishes none of these, and a battery at 0 would be a lie.
    test "a device that reported no charge draws no battery", %{state: state} do
      assert state.view.battery_percent == nil
    end

    test "the same battery event twice draws one frame", %{state: state} do
      event = %DeviceEvents.BatteryChanged{percent: 20, low?: true}

      {:ok, state} = PirateAudio.handle_event(event, state)
      RecordingScreen.forget()

      {:ok, _state} = PirateAudio.handle_event(event, state)

      assert frames() == 0
    end

    test "an event of another topic changes nothing and draws nothing", %{state: state} do
      {:ok, ^state} = PirateAudio.handle_event(%URI{}, state)

      assert frames() == 0
    end
  end

  describe "standby" do
    # A panel that sleeps under a light that is on shows white, so the light goes first.
    test "turns the backlight off before it puts the panel to sleep", %{state: state} do
      {:ok, state} = PirateAudio.handle_event(started(), state)
      RecordingScreen.forget()

      {:ok, state} = PirateAudio.handle_event(%Player.Standby{entered?: true}, state)

      refute state.awake?
      assert RecordingScreen.backlight_line() == [0]
      assert @display_off in sent()
      assert @sleep_in in sent()
      assert frames() == 0
    end

    test "holds the track, so a person sees it again on the way back", %{state: state} do
      {:ok, state} = PirateAudio.handle_event(started(), state)

      {:ok, state} = PirateAudio.handle_event(%Player.Standby{entered?: true}, state)

      assert state.view.state == :playing
      assert state.view.title == "The Detail"
    end

    test "an event in standby moves the view and writes no byte", %{state: state} do
      {:ok, state} = PirateAudio.handle_event(%Player.Standby{entered?: true}, state)
      RecordingScreen.forget()

      {:ok, state} = PirateAudio.handle_event(started(), state)

      assert state.view.title == "The Detail"
      assert frames() == 0
    end

    # A light that came on before the draw would show the frame that the panel held
    # before, so the order is wake, draw, light.
    test "leaving standby wakes the panel, draws, and lights it after that", %{state: state} do
      {:ok, state} = PirateAudio.handle_event(started(), state)
      {:ok, state} = PirateAudio.handle_event(%Player.Standby{entered?: true}, state)
      RecordingScreen.forget()

      {:ok, state} = PirateAudio.handle_event(%Player.Standby{entered?: false}, state)

      assert state.awake?
      assert frames() == 1
      assert RecordingScreen.backlight_line() == [1]
      assert @sleep_out in sent()
      assert @display_on in sent()
    end

    test "a second standby writes nothing more", %{state: state} do
      {:ok, state} = PirateAudio.handle_event(%Player.Standby{entered?: true}, state)
      RecordingScreen.forget()

      {:ok, state} = PirateAudio.handle_event(%Player.Standby{entered?: true}, state)

      refute state.awake?
      assert RecordingScreen.backlight_line() == []
      assert sent() == []
    end

    test "leaving standby that never began writes nothing", %{state: state} do
      RecordingScreen.forget()

      {:ok, state} = PirateAudio.handle_event(%Player.Standby{entered?: false}, state)

      assert state.awake?
      assert RecordingScreen.backlight_line() == []
      assert sent() == []
    end
  end

  test "each frame is the whole screen, in RGB565", %{state: state} do
    {:ok, _state} = PirateAudio.handle_event(started(), state)

    assert [{@memory_write, pixels}] =
             Enum.filter(RecordingScreen.commands(), &match?({@memory_write, _}, &1))

    {width, height} = PirateAudio.St7789.size()
    assert byte_size(pixels) == width * height * 2
  end

  test "terminate turns the backlight off", %{state: state} do
    :ok = PirateAudio.terminate(:normal, state)

    assert List.last(RecordingScreen.backlight_line()) == 0
  end

  # Emerge refuses a runtime path by its extension, and a name of the cache carries no
  # type, so the thumbnails are the one kind that it may read.
  test "it lets Emerge read a thumbnail of the cache and nothing else" do
    options = PirateAudio.asset_options()
    paths = Keyword.fetch!(options, :runtime_paths)

    assert Keyword.fetch!(paths, :enabled)
    assert Keyword.fetch!(paths, :extensions) == [".thumbnail"]
    assert Keyword.fetch!(paths, :allowlist) == [MyHiFi.Cache.directory()]
  end

  # A tap is a press and the release that follows it. This board reads a long press, so
  # the press alone says nothing until one of the two arrives.
  defp tap_button(state, line) do
    now = System.monotonic_time(:nanosecond)
    {:ok, state} = PirateAudio.handle_info({:circuits_gpio, line, now, 0}, state)

    PirateAudio.handle_info({:circuits_gpio, line, now + 100_000_000, 1}, state)
  end

  defp frames do
    RecordingScreen.commands()
    |> Enum.count(&match?({@memory_write, _pixels}, &1))
  end

  defp sent, do: Enum.map(RecordingScreen.commands(), fn {command, _payload} -> command end)

  defp started do
    %Player.Started{
      source: MyHiFi.Source.Podcasts,
      track: %{ref: "detail", title: "The Detail", subtitle: "RNZ", duration_ms: 1_284_000},
      live?: false,
      position_ms: 30_000
    }
  end

  # This board holds four buttons at the corners of the screen, and two of them work.
  # See the moduledoc for the measurement that found that.
  describe "the buttons" do
    test "a press says which button, and never what it means", %{state: state} do
      MyHiFi.Event.subscribe(:input)

      {:ok, _state} = tap_button(state, 5)

      assert_receive %MyHiFi.Event.Input.ButtonPressed{
        peripheral: MyHiFi.Peripheral.PirateAudio,
        button: 1
      }
    end

    test "the second line is the second button", %{state: state} do
      MyHiFi.Event.subscribe(:input)

      {:ok, _state} = tap_button(state, 6)

      assert_receive %MyHiFi.Event.Input.ButtonPressed{button: 2}
    end

    # GPIO 16 and 24 hold the two buttons that this board cannot read.
    test "a line that this board does not read says nothing", %{state: state} do
      MyHiFi.Event.subscribe(:input)

      {:ok, _state} = tap_button(state, 16)

      refute_receive %MyHiFi.Event.Input.ButtonPressed{}, 200
    end
  end

  # The panel sleeps in standby, and this message is the one thing worth waking it for.
  # See `MyHiFi.SwitchOff`.
  describe "safe to switch off" do
    test "it wakes the panel and says so", %{state: state} do
      {:ok, state} = PirateAudio.handle_event(%Player.Standby{entered?: true}, state)
      refute state.awake?
      RecordingScreen.forget()

      {:ok, state} =
        PirateAudio.handle_event(%DeviceEvents.SafeToSwitchOff{safe?: true}, state)

      assert state.awake?
      assert state.view.safe_to_switch_off?
      assert Screen.headline(state.view) == "SAFE TO\nSWITCH OFF"
      assert frames() == 1
      assert RecordingScreen.backlight_line() == [1]
    end

    # A screen that stayed lit would use the cell that a person is about to stop using.
    test "it sleeps again after the period", %{state: state} do
      {:ok, state} = PirateAudio.handle_event(%Player.Standby{entered?: true}, state)

      {:ok, state} =
        PirateAudio.handle_event(%DeviceEvents.SafeToSwitchOff{safe?: true}, state)

      RecordingScreen.forget()

      {:ok, state} = PirateAudio.handle_info(:sleep_again, state)

      refute state.awake?
      assert RecordingScreen.backlight_line() == [0]
    end

    # A person who woke the device asked for the work to go on.
    test "a person who wakes the device takes the message away", %{state: state} do
      {:ok, state} =
        PirateAudio.handle_event(%DeviceEvents.SafeToSwitchOff{safe?: true}, state)

      {:ok, state} =
        PirateAudio.handle_event(%DeviceEvents.SafeToSwitchOff{safe?: false}, state)

      refute state.view.safe_to_switch_off?
    end

    # The timer fires whether or not the message is still there, so it must read the
    # view and not sleep a screen that a person woke.
    test "the timer sleeps nothing when the message is gone", %{state: state} do
      {:ok, state} = PirateAudio.handle_event(started(), state)
      RecordingScreen.forget()

      {:ok, state} = PirateAudio.handle_info(:sleep_again, state)

      assert state.awake?
      assert RecordingScreen.backlight_line() == []
    end
  end
end
