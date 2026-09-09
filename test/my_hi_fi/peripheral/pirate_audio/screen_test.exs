defmodule MyHiFi.Peripheral.PirateAudio.ScreenTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Peripheral.PirateAudio.Screen

  # One flat red picture of 8 by 8 pixels. A flat colour is what makes a measurement of
  # the pixels mean something: every place that the picture covers holds one value.
  @red_png Base.decode64!(
             "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGO4o6GBFTEMLQkAe3tLAfuiUfAAAAAASUVORK5CYII="
           )

  describe "headline/1" do
    test "a track gives its title" do
      view = %{Screen.new() | state: :playing, title: "Tiny Ruins"}

      assert Screen.headline(view) == "Tiny Ruins"
    end

    test "a device that plays nothing names itself, so a person knows it is awake" do
      assert Screen.headline(Screen.new()) == "PiFi"
      assert Screen.headline(%{Screen.new() | device_name: "Kitchen"}) == "Kitchen"
    end

    test "a state with no title says the state in words" do
      assert Screen.headline(%{Screen.new() | state: :buffering}) == "Buffering"
      assert Screen.headline(%{Screen.new() | state: :playing}) == "Nothing is playing"
    end

    test "a failure says what went wrong, and says Failed when it holds no reason" do
      assert Screen.headline(%{Screen.new() | state: :failed, message: "no route"}) == "no route"
      assert Screen.headline(%{Screen.new() | state: :failed}) == "Failed"
    end

    test "a title wins over the state, because a person reads the track first" do
      view = %{Screen.new() | state: :paused, title: "Waiata"}

      assert Screen.headline(view) == "Waiata"
    end
  end

  describe "stopped/1" do
    # A person who stopped the music reads the name of the device and the charge of the
    # cell. Neither one belongs to the track that went.
    test "it clears the track and keeps the device and the hardware" do
      playing = %{
        Screen.new()
        | state: :playing,
          title: "Tiny Ruins",
          subtitle: "Ceremony",
          battery_percent: 42,
          low_battery?: true,
          device_name: "Kitchen",
          splash_path: "/root/cache/artwork/abc.thumbnail"
      }

      stopped = Screen.stopped(playing)

      assert stopped.state == :stopped
      assert stopped.title == nil
      assert stopped.subtitle == nil
      assert stopped.battery_percent == 42
      assert stopped.low_battery?
      assert stopped.device_name == "Kitchen"
      assert stopped.splash_path == "/root/cache/artwork/abc.thumbnail"
    end
  end

  describe "the picture of the idle screen" do
    setup [:splash_file]

    test "it fills the field, and the scrim keeps the name readable", context do
      {width, height} = Screen.size()
      view = %{Screen.new() | device_name: "Kitchen", splash_path: context.path}

      pixels =
        view
        |> Screen.render()
        |> EmergeSkia.render_to_pixels(
          otp_app: :my_hi_fi,
          width: width,
          height: height,
          assets: context.assets
        )

      assert {red, _green, _blue} = pixel(pixels, width, 4, 40)
      assert red > 150
      assert {red, green, blue} = pixel(pixels, width, 4, height - 4)
      assert red < 90 and green < 90 and blue < 90
    end

    # The cover of the track wins, because that is what a person is listening to.
    test "the artwork of a track takes the place of the picture", context do
      {width, _height} = Screen.size()

      view = %{
        Screen.new()
        | state: :playing,
          title: "Tiny Ruins",
          splash_path: context.path
      }

      assert {red, green, blue} = pixel(field(view, context), width, 4, 40)
      assert red < 40 and green < 40 and blue < 40
    end
  end

  describe "the timeline" do
    # The bar and the numbers are the same fact twice, and a person needs both: the bar
    # at a glance, and the numbers when they want to know how long is left.
    test "a track draws the point, the end and a bar between them" do
      view = %{
        Screen.new()
        | state: :playing,
          title: "Tiny Ruins",
          position_ms: 812_000,
          duration_ms: 4_275_000
      }

      # 812 of 4275 seconds is 19 percent, and the bar spans the width of the scrim.
      assert_in_delta bar_width(view), 0.19 * 212, 3
    end

    # A position past the end of a track is what a decoder gives when a file is longer
    # than its own tag says, and a bar that ran off the glass would be the only sign.
    test "a position past the end fills the bar and no more" do
      view = %{
        Screen.new()
        | state: :playing,
          title: "Tiny Ruins",
          position_ms: 9_000_000,
          duration_ms: 4_275_000
      }

      assert_in_delta bar_width(view), 212, 3
    end

    # A bar of no width draws nothing, and a track that just began still needs to show
    # that it began.
    test "a track that just began draws a bar that a person can see" do
      view = %{Screen.new() | state: :playing, title: "Tiny Ruins", duration_ms: 4_275_000}

      assert bar_width(view) >= 2
    end

    # A live stream has no end, so a bar would draw a lie.
    test "a live stream draws no bar" do
      view = %{Screen.new() | state: :playing, title: "RNZ National", position_ms: 95_000}

      assert bar_width(view) == 0
    end

    test "a device that plays nothing draws no bar" do
      assert bar_width(Screen.new()) == 0
    end

    # A person who must charge the device reads that and nothing else.
    test "a flat cell takes the bar away with the subtitle" do
      view = %{
        Screen.new()
        | state: :playing,
          title: "Tiny Ruins",
          position_ms: 812_000,
          duration_ms: 4_275_000,
          low_battery?: true
      }

      assert bar_width(view) == 0
    end
  end

  describe "the network" do
    # **A network that carries the music draws nothing.** A person whose music plays
    # needs no mark that says so, and this screen is 240 pixels wide.
    test "a network that carries the music leaves the corner alone" do
      assert corner(:internet) == corner(nil)
      assert {red, green, blue} = corner(:internet)
      assert red < 40 and green < 40 and blue < 40
    end

    # Rose says that a person must act, which is what the low battery band says with
    # the same colour.
    test "a device with no way out of its network draws a band in the corner" do
      assert {red, green, blue} = corner(:lan)
      assert red > 90 and green < 60 and blue < 90
    end

    test "a device with no network at all draws it as well" do
      assert corner(:disconnected) == corner(:lan)
    end

    # The battery sits at the other end of the row, so a warning that arrives moves
    # nothing that a person was already reading.
    test "the battery does not move when the warning arrives" do
      assert battery_corner(:internet) == battery_corner(:lan)
    end

    # A stop clears the track. What the hardware says is not the track.
    test "a stop keeps what the network says" do
      stopped = Screen.stopped(%{Screen.new() | state: :playing, network: :lan})

      assert stopped.network == :lan
    end

    defp view_with(network) do
      %{
        Screen.new()
        | state: :playing,
          title: "Tiny Ruins",
          battery_percent: 94,
          network: network
      }
    end

    defp pixels_of(network) do
      {width, height} = Screen.size()

      network
      |> view_with()
      |> Screen.render()
      |> EmergeSkia.render_to_pixels(otp_app: :my_hi_fi, width: width, height: height)
    end

    # Inside the band that the warning draws, at the top left, where the artwork would
    # otherwise show.
    defp corner(network) do
      {width, _height} = Screen.size()

      pixel(pixels_of(network), width, 14, 18)
    end

    # The right end of the row, which is where the battery sits.
    defp battery_corner(network) do
      {width, _height} = Screen.size()

      pixel(pixels_of(network), width, width - 14, 18)
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

    # The scrim is what makes the words readable over any picture, so a test measures it
    # rather than a person reading a render. A column inside the padding holds no glyph,
    # so every row of it is the band and nothing else.
    test "the band behind the words is dark enough to read light text on" do
      {width, height} = Screen.size()

      pixels =
        %{Screen.new() | state: :playing, title: "Tiny Ruins", subtitle: "Ceremony"}
        |> Screen.render()
        |> EmergeSkia.render_to_pixels(otp_app: :my_hi_fi, width: width, height: height)

      for y <- [height - 40, height - 20, height - 4] do
        assert {red, green, blue} = pixel(pixels, width, 4, y)
        assert red <= 80 and green <= 80 and blue <= 80
      end
    end
  end

  # Emerge refuses a runtime path by its extension, so the file carries the name that
  # the cache gives a thumbnail. See `MyHiFi.Peripheral.PirateAudio.asset_options/0`.
  defp splash_file(_context) do
    directory = Path.join(System.tmp_dir!(), "splash_#{:erlang.unique_integer([:positive])}")
    path = Path.join(directory, "splash.thumbnail")

    File.mkdir_p!(directory)
    File.write!(path, @red_png)
    on_exit(fn -> File.rm_rf(directory) end)

    assets = [runtime_paths: [enabled: true, allowlist: [directory], extensions: [".thumbnail"]]]

    %{path: path, assets: assets}
  end

  defp field(view, context) do
    {width, height} = Screen.size()

    view
    |> Screen.render()
    |> EmergeSkia.render_to_pixels(
      otp_app: :my_hi_fi,
      width: width,
      height: height,
      assets: context.assets
    )
  end

  # The bar is the one bright row at the foot of the screen, and the words above it hold
  # no row of their own. A count of the light pixels of that row therefore measures the
  # bar, and 0 says that the screen drew none.
  defp bar_width(view) do
    {width, height} = Screen.size()

    pixels =
      view
      |> Screen.render()
      |> EmergeSkia.render_to_pixels(otp_app: :my_hi_fi, width: width, height: height)

    Enum.count(0..(width - 1), fn x ->
      {red, green, blue} = pixel(pixels, width, x, height - 14)

      red > 200 and green > 200 and blue > 200
    end)
  end

  defp pixel(pixels, width, x, y) do
    offset = (y * width + x) * 4
    <<_::binary-size(^offset), red, green, blue, _alpha, _rest::binary>> = pixels

    {red, green, blue}
  end

  defp views do
    [
      Screen.new(),
      %{Screen.new() | state: :buffering},
      %{Screen.new() | state: :playing, title: "Tiny Ruins", subtitle: "Ceremony"},
      %{Screen.new() | state: :paused, title: "Tiny Ruins", subtitle: "Ceremony"},
      %{Screen.new() | state: :failed, message: "no route to host"},
      %{
        Screen.new()
        | state: :playing,
          title: "A Title That Is Long Enough To Wrap Onto More Than One Line",
          subtitle: "RNZ National"
      },
      %{Screen.new() | state: :playing, title: "Tiny Ruins", network: :disconnected},
      %{Screen.new() | state: :playing, title: "Tiny Ruins", network: :lan, battery_percent: 4}
    ]
  end
end
