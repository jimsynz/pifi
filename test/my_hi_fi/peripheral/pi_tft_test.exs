defmodule MyHiFi.Peripheral.PiTftTest do
  # `MyHiFi.Test.RecordingScreen` is a named process, so two of these cannot run at
  # the same time.
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Event.Player
  alias MyHiFi.Peripheral.PiTft
  alias MyHiFi.Test.RecordingScreen

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
    assert RecordingScreen.backlight() == [0]
  end

  test "it reads the player topic only" do
    assert PiTft.subscriptions() == [:player]
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
