defmodule MyHiFi.Peripheral.PiTft.ScreenTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Peripheral.PiTft.Screen

  # One flat red picture of 8 by 8 pixels. A flat colour is what makes a measurement of
  # the pixels mean something: every place that the picture covers holds one value.
  @red_png Base.decode64!(
             "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGO4o6GBFTEMLQkAe3tLAfuiUfAAAAAASUVORK5CYII="
           )

  describe "clock/1" do
    test "gives minutes and seconds under an hour" do
      assert Screen.clock(0) == "0:00"
      assert Screen.clock(9_000) == "0:09"
      assert Screen.clock(69_000) == "1:09"
      assert Screen.clock(3_599_000) == "59:59"
    end

    test "gives hours as well, because an episode runs that long" do
      assert Screen.clock(3_600_000) == "1:00:00"
      assert Screen.clock(5_832_000) == "1:37:12"
    end
  end

  describe "status_text/1" do
    test "a device that plays nothing names itself, so a person knows it is awake" do
      assert Screen.status_text(%{Screen.new() | device_name: "Kitchen"}) == "Kitchen"
    end

    test "tells a person which state the player is in" do
      assert Screen.status_text(Screen.new()) == "MyHiFi"
      assert Screen.status_text(%{Screen.new() | state: :playing}) == "Playing"
      assert Screen.status_text(%{Screen.new() | state: :paused}) == "Paused"
      assert Screen.status_text(%{Screen.new() | state: :failed}) == "Failed"
    end

    test "says live for a stream with no end" do
      view = %{Screen.new() | state: :playing, live?: true}

      assert Screen.status_text(view) == "Live"
    end

    test "counts the buffer while it fills" do
      view = %{Screen.new() | state: :buffering, percent: 42}

      assert Screen.status_text(view) == "Buffering 42%"
    end

    test "says paused before it says live, because a person needs the control first" do
      view = %{Screen.new() | state: :paused, live?: true}

      assert Screen.status_text(view) == "Paused"
    end
  end

  describe "stopped/1" do
    # A person who stopped the music reads the name of the device and the charge of the
    # cell. Neither one belongs to the track that went.
    test "it clears the track and keeps the device and the hardware" do
      playing = %{
        Screen.new()
        | state: :playing,
          title: "The Detail",
          position_ms: 512_000,
          duration_ms: 1_284_000,
          battery_percent: 42,
          low_battery?: true,
          device_name: "Kitchen",
          splash_path: "/root/cache/artwork/abc.thumbnail"
      }

      stopped = Screen.stopped(playing)

      assert stopped.state == :stopped
      assert stopped.title == nil
      assert stopped.position_ms == 0
      assert stopped.battery_percent == 42
      assert stopped.low_battery?
      assert stopped.device_name == "Kitchen"
      assert stopped.splash_path == "/root/cache/artwork/abc.thumbnail"
    end
  end

  describe "the picture of the idle screen" do
    setup [:splash_file]

    test "it fills the screen, and the name reads over it", %{path: path, assets: assets} do
      {width, height} = Screen.size()
      view = %{Screen.new() | device_name: "Kitchen", splash_path: path}

      pixels =
        view
        |> Screen.render()
        |> EmergeSkia.render_to_pixels(
          otp_app: :my_hi_fi,
          width: width,
          height: height,
          assets: assets
        )

      assert byte_size(pixels) == width * height * 4

      # The picture is one flat red, so a row above the band holds it and the band at
      # the foot is dark enough to read light text on.
      assert {red, _green, _blue} = pixel(pixels, width, 4, 40)
      assert red > 150
      assert {red, green, blue} = pixel(pixels, width, 4, height - 4)
      assert red < 90 and green < 90 and blue < 90
    end

    # A track that plays holds the picture of that track, and the splash belongs to the
    # moment when the device plays nothing.
    test "a track that plays draws the layout of a track", %{path: path, assets: assets} do
      {width, height} = Screen.size()

      view = %{
        Screen.new()
        | state: :playing,
          title: "Tiny Ruins",
          device_name: "Kitchen",
          splash_path: path
      }

      pixels =
        view
        |> Screen.render()
        |> EmergeSkia.render_to_pixels(
          otp_app: :my_hi_fi,
          width: width,
          height: height,
          assets: assets
        )

      assert {red, green, blue} = pixel(pixels, width, 160, 120)
      assert red < 40 and green < 40 and blue < 40
    end
  end

  describe "render/1" do
    test "draws every state at the size of the screen" do
      {width, height} = Screen.size()

      for view <- views() do
        pixels =
          view
          |> Screen.render()
          |> EmergeSkia.render_to_pixels(otp_app: :my_hi_fi, width: width, height: height)

        assert byte_size(pixels) == width * height * 4
      end
    end

    test "a title that is far longer than the screen still draws" do
      {width, height} = Screen.size()
      view = %{Screen.new() | state: :playing, title: String.duplicate("A long title. ", 40)}

      pixels =
        view
        |> Screen.render()
        |> EmergeSkia.render_to_pixels(otp_app: :my_hi_fi, width: width, height: height)

      assert byte_size(pixels) == width * height * 4
    end

    test "a position past the duration does not draw a bar wider than the screen" do
      {width, height} = Screen.size()
      view = %{Screen.new() | state: :playing, position_ms: 900_000, duration_ms: 60_000}

      pixels =
        view
        |> Screen.render()
        |> EmergeSkia.render_to_pixels(otp_app: :my_hi_fi, width: width, height: height)

      assert byte_size(pixels) == width * height * 4
    end
  end

  describe "the colour of the artwork" do
    # The bar of the progress and the pill of the status take the colour, so a view
    # that holds one draws pixels that a view without one does not.
    test "it reaches the pixels of the screen" do
      {width, height} = Screen.size()

      playing = %{
        Screen.new()
        | state: :playing,
          title: "The Detail",
          position_ms: 30_000,
          duration_ms: 60_000
      }

      assert pixels(playing, width, height) !=
               pixels(%{playing | accent: {230, 90, 60}}, width, height)
    end

    # A picture of greys gives no colour, and the screen then draws what it drew
    # before. See `MyHiFi.Artwork.Accent`.
    test "a view that holds no colour draws the colours of the states" do
      {width, height} = Screen.size()
      view = %{Screen.new() | state: :playing, title: "The Detail"}

      assert pixels(view, width, height) == pixels(%{view | accent: nil}, width, height)
    end
  end

  # Emerge refuses a runtime path by its extension, so the file carries the name that
  # the cache gives a thumbnail. See `MyHiFi.Peripheral.PiTft.asset_options/0`.
  defp splash_file(_context) do
    directory = Path.join(System.tmp_dir!(), "splash_#{:erlang.unique_integer([:positive])}")
    path = Path.join(directory, "splash.thumbnail")

    File.mkdir_p!(directory)
    File.write!(path, @red_png)
    on_exit(fn -> File.rm_rf(directory) end)

    assets = [runtime_paths: [enabled: true, allowlist: [directory], extensions: [".thumbnail"]]]

    %{path: path, assets: assets}
  end

  defp pixel(pixels, width, x, y) do
    offset = (y * width + x) * 4
    <<_::binary-size(^offset), red, green, blue, _alpha, _rest::binary>> = pixels

    {red, green, blue}
  end

  defp pixels(view, width, height) do
    view
    |> Screen.render()
    |> EmergeSkia.render_to_pixels(otp_app: :my_hi_fi, width: width, height: height)
  end

  defp views do
    [
      Screen.new(),
      %{Screen.new() | state: :buffering, percent: 42, title: "Concert FM", live?: true},
      %{
        Screen.new()
        | state: :playing,
          title: "RNZ National",
          subtitle: "Checkpoint",
          live?: true
      },
      %{
        Screen.new()
        | state: :playing,
          title: "The Detail",
          subtitle: "RNZ",
          position_ms: 512_000,
          duration_ms: 1_284_000
      },
      %{Screen.new() | state: :paused, title: "The Detail", position_ms: 512_000},
      %{Screen.new() | state: :failed, message: "The stream did not answer"}
    ]
  end
end
