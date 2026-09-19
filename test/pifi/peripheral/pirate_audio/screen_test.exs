defmodule PiFi.Peripheral.PirateAudio.ScreenTest do
  use ExUnit.Case, async: true

  alias PiFi.Peripheral.PirateAudio.Screen
  alias PiFi.Screen.{Battery, Network, Style}
  alias PiFi.Test.Drawing
  alias PiFi.Test.Tree

  # The card of the words stands away from the glass by this much. This is
  # `@panel_margin` of the screen.
  @margin 6

  # The part of the bar that is full, when the track is at its end. The card is 240
  # less the margin, the padding and the border of the card and of the bar.
  @full_bar 202

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
        |> Drawing.pixels(width, height, context.assets)

      assert {red, _green, _blue} = pixel(pixels, width, 4, 40)
      assert red > 150

      # The card of the name stands away from the glass, so the picture shows in the
      # margin and the card itself is a few pixels in from it.
      assert {red, green, blue} = pixel(pixels, width, @margin + 6, height - @margin - 6)
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

  # **These read the tree and not the pixels.** A test that counted the pixels of one
  # colour broke on every change of a margin or a border and said nothing that a
  # person could read. See `PiFi.Test.Tree`.
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

      tree = Screen.render(view)

      assert "13:32" in Tree.texts(tree)
      assert "1:11:15" in Tree.texts(tree)

      # 812 of 4275 seconds is 19 percent.
      assert_in_delta filled_bar(tree), 0.19 * @full_bar, 1
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

      assert filled_bar(Screen.render(view)) == @full_bar
    end

    # A bar of no width draws nothing, and a track that just began still needs to show
    # that it began.
    test "a track that just began draws a bar that a person can see" do
      view = %{Screen.new() | state: :playing, title: "Tiny Ruins", duration_ms: 4_275_000}

      assert filled_bar(Screen.render(view)) >= 2
    end

    # A live stream has no end, so a bar would draw a lie. It still says how long it
    # has been playing.
    test "a live stream draws the time and no bar" do
      view = %{Screen.new() | state: :playing, title: "RNZ National", position_ms: 95_000}

      tree = Screen.render(view)

      refute drawn_bar?(tree)
      assert "1:35" in Tree.texts(tree)
    end

    test "a device that plays nothing draws no bar" do
      refute drawn_bar?(Screen.render(Screen.new()))
    end

    # A person who must charge the device reads that and nothing else.
    test "a flat cell takes the bar away with the subtitle" do
      view = %{
        Screen.new()
        | state: :playing,
          title: "Tiny Ruins",
          subtitle: "Ceremony",
          position_ms: 812_000,
          duration_ms: 4_275_000,
          low_battery?: true
      }

      tree = Screen.render(view)

      refute drawn_bar?(tree)
      refute "Ceremony" in Tree.texts(tree)
      assert "LOW BATTERY\nCHARGE NOW" in Tree.texts(tree)
    end
  end

  # The chip at the head says the state, and the card at the foot says the track. Both
  # screens of this device draw that row. See `PiFi.Peripheral.PiTft.Screen`.
  describe "the chip of the state" do
    test "it says what the player is doing" do
      for {state, word} <- [
            {:playing, "PLAYING"},
            {:paused, "PAUSED"},
            {:buffering, "BUFFERING"},
            {:failed, "FAILED"}
          ] do
        view = %{Screen.new() | state: state, title: "Tiny Ruins"}

        assert word in Tree.texts(Screen.render(view)), "#{state} draws no #{word}"
      end
    end

    # A person who must charge the device reads that in the chip as well as in the card.
    test "a flat cell takes the chip" do
      view = %{Screen.new() | state: :playing, title: "Tiny Ruins", low_battery?: true}

      assert "CHARGE" in Tree.texts(Screen.render(view))
    end

    # The card carries the name of the device in that moment, and a chip beside it
    # would say the same thing twice.
    test "a device that plays nothing draws no chip" do
      refute Enum.any?(Screen.render(Screen.new()) |> Tree.texts(), &(&1 in states()))
    end
  end

  # **A mark that is there at all is the signal.** Which colour belongs to which fault
  # is the business of `PiFi.Screen.Network`, and the test of that module names it, so
  # this asks only whether the screen draws the mark and whether it draws the battery.
  describe "what the hardware says" do
    test "a network that carries the music draws no mark" do
      refute mark?(:internet)
      refute mark?(nil)
    end

    test "a device with no way out of its network draws a mark" do
      assert mark?(:lan)
    end

    test "a device with no network at all draws a mark" do
      assert mark?(:disconnected)
    end

    test "a device with a cell draws the charge of it" do
      view = %{view_with(:internet) | battery_percent: 94}

      assert Tree.shows?(Screen.render(view), Battery.render(94, false))
    end

    # **A device on the mains draws no battery at all.** It has no gauge, so a battery
    # at 0 would be a lie.
    test "a device with no cell draws no battery" do
      view = %{view_with(:internet) | battery_percent: nil}

      refute Enum.any?(0..100, &Tree.shows?(Screen.render(view), Battery.render(&1, false)))
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

    defp mark?(network) do
      tree = network |> view_with() |> Screen.render()

      Enum.any?([:lan, :disconnected], &Tree.shows?(tree, Network.render(&1)))
    end
  end

  describe "render/1" do
    test "draws every state at the size of the screen" do
      {width, height} = Screen.size()

      for view <- views() do
        pixels =
          view
          |> Screen.render()
          |> Drawing.pixels(width, height)

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
        |> Drawing.pixels(width, height)

      for y <- [height - 40, height - 20, height - 4] do
        assert {red, green, blue} = pixel(pixels, width, 4, y)
        assert red <= 80 and green <= 80 and blue <= 80
      end
    end
  end

  # **The part of the bar that is full is the one element filled with cyan.** The
  # offset shadow of the card is cyan as well, and that is a shadow and not a fill, so
  # nothing else on this screen answers.
  defp bar_fill(tree) do
    Tree.find_by(tree, &(&1.attrs[:background] == Style.cyan()))
  end

  defp drawn_bar?(tree), do: bar_fill(tree) != nil

  defp filled_bar(tree) do
    {:px, pixels} = bar_fill(tree).attrs.width

    pixels
  end

  defp states, do: ["PLAYING", "PAUSED", "BUFFERING", "FAILED", "CHARGE"]

  # Emerge refuses a runtime path by its extension, so the file carries the name that
  # the cache gives a thumbnail. See `PiFi.Screen.Renderer.assets/0`.
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
    |> Drawing.pixels(width, height, context.assets)
  end

  # The bar is the one bright row at the foot of the screen, and the words above it hold
  # no row of their own. A count of the light pixels of that row therefore measures the
  # bar, and 0 says that the screen drew none.
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
