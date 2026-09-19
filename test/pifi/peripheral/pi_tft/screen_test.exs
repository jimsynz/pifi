defmodule PiFi.Peripheral.PiTft.ScreenTest do
  use ExUnit.Case, async: true

  alias PiFi.Peripheral.PiTft.Screen
  alias PiFi.Screen.{Battery, Network, Style}
  alias PiFi.Test.Drawing
  alias PiFi.Test.Tree

  # One flat red picture of 8 by 8 pixels. A flat colour is what makes a measurement of
  # the pixels mean something: every place that the picture covers holds one value.
  @red_png Base.decode64!(
             "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGO4o6GBFTEMLQkAe3tLAfuiUfAAAAAASUVORK5CYII="
           )

  describe "status_text/1" do
    test "a device that plays nothing names itself, so a person knows it is awake" do
      assert Screen.status_text(%{Screen.new() | device_name: "Kitchen"}) == "Kitchen"
    end

    test "tells a person which state the player is in" do
      assert Screen.status_text(Screen.new()) == "PiFi"
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
        |> Drawing.pixels(width, height, assets)

      assert byte_size(pixels) == width * height * 4

      # **This one measures the pixels on purpose.** The claim is that light text reads
      # over any picture, and that is a claim about contrast and not about the layout.
      # The picture is one flat red, so a row above the card holds it, and the card at
      # the foot is dark enough to read light text on.
      assert {red, _green, _blue} = pixel(pixels, width, 4, 40)
      assert red > 150

      # The card stands away from the glass by 8, so the picture shows in the margin
      # and the card itself is a few pixels in from it.
      assert {red, green, blue} = pixel(pixels, width, 14, height - 14)
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
        |> Drawing.pixels(width, height, assets)

      assert {red, green, blue} = pixel(pixels, width, 160, 120)
      assert red < 40 and green < 40 and blue < 40
    end
  end

  # **A mark that is there at all is the signal**, and the colour says which fault. See
  # `PiFi.Screen.Network`.
  # **A mark that is there at all is the signal.** Which colour belongs to which fault
  # is the business of `PiFi.Screen.Network`, and the test of that module names it, so
  # this asks only whether the screen draws the mark and whether it draws the battery.
  # See `PiFi.Test.Tree`.
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
      assert Tree.shows?(Screen.render(view_with(:internet)), Battery.render(94, false))
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

    # **The idle layout holds no status row**, so it draws its own corner. A device on
    # the mains holds no gauge and it can still hold a router that is off, so that row
    # must draw for one.
    test "the idle screen of a device with no gauge still draws the mark" do
      view = %{
        Screen.new()
        | device_name: "Kitchen",
          splash_path: "/nowhere/splash.thumbnail",
          battery_percent: nil,
          network: :disconnected
      }

      assert Tree.shows?(Screen.render(view), Network.render(:disconnected))
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

  # **The menu takes the whole screen**, because a list needs the rows. The event
  # carries the whole level and this screen draws the rows that fit.
  describe "the menu" do
    defp menu_view(rows, index) do
      %{
        Screen.new()
        | menu: %{
            title: "Playlists",
            rows: Enum.map(rows, &%{title: &1, subtitle: nil, kind: :open}),
            index: index,
            depth: 1
          }
      }
    end

    defp menu_pixels(view) do
      {width, height} = Screen.size()

      view
      |> Screen.render()
      |> Drawing.pixels(width, height)
    end

    test "it draws a level at the size of the screen" do
      {width, height} = Screen.size()

      assert byte_size(menu_pixels(menu_view(["Alpha", "Bravo"], 0))) == width * height * 4
    end

    # A person reads this screen across a room, so the row that they are on draws a
    # band and not a colour of the text alone.
    test "the row that a person is on draws a band" do
      first = menu_pixels(menu_view(["Alpha", "Bravo"], 0))
      second = menu_pixels(menu_view(["Alpha", "Bravo"], 1))

      refute first == second
    end

    # **The window holds still while it can.** A list that scrolled on every press would
    # move under a person who is reading it.
    test "a level of more rows than fit draws a window of them" do
      rows = Enum.map(1..40, &"Row #{&1}")

      {width, height} = Screen.size()

      for index <- [0, 5, 20, 39] do
        assert byte_size(menu_pixels(menu_view(rows, index))) == width * height * 4
      end

      refute menu_pixels(menu_view(rows, 0)) == menu_pixels(menu_view(rows, 39))
    end

    test "a level of no rows still draws" do
      {width, height} = Screen.size()

      assert byte_size(menu_pixels(menu_view([], 0))) == width * height * 4
    end

    # A row that leads somewhere, a row that plays and a row that acts on the device
    # each draw their own mark.
    test "each kind of row draws" do
      view = %{
        Screen.new()
        | menu: %{
            title: "Menu",
            rows: [
              %{title: "Now playing", subtitle: nil, kind: :do},
              %{title: "Internet radio", subtitle: nil, kind: :open},
              %{title: "Alpha", subtitle: "MP3, 128 kbps", kind: :play}
            ],
            index: 1,
            depth: 0
          }
      }

      {width, height} = Screen.size()

      assert byte_size(menu_pixels(view)) == width * height * 4
    end

    # A title that is longer than the screen must not push the mark off the row.
    test "a title that is far longer than the screen still draws" do
      {width, height} = Screen.size()
      long = String.duplicate("A long name. ", 40)

      assert byte_size(menu_pixels(menu_view([long], 0))) == width * height * 4
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

    test "a title that is far longer than the screen still draws" do
      {width, height} = Screen.size()
      view = %{Screen.new() | state: :playing, title: String.duplicate("A long title. ", 40)}

      pixels =
        view
        |> Screen.render()
        |> Drawing.pixels(width, height)

      assert byte_size(pixels) == width * height * 4
    end

    test "a position past the duration does not draw a bar wider than the screen" do
      {width, height} = Screen.size()
      view = %{Screen.new() | state: :playing, position_ms: 900_000, duration_ms: 60_000}

      pixels =
        view
        |> Screen.render()
        |> Drawing.pixels(width, height)

      assert byte_size(pixels) == width * height * 4
    end
  end

  # **The screen reads no colour of the artwork**, so the chip of a state holds one
  # colour whatever the cover is. See `PiFi.Screen.Style.state_colour/1`.
  describe "the chip of the state" do
    test "it says what the player is doing" do
      for {state, word} <- [
            {:playing, "PLAYING"},
            {:paused, "PAUSED"},
            {:failed, "FAILED"}
          ] do
        view = %{Screen.new() | state: state, title: "The Detail"}

        assert word in Tree.texts(Screen.render(view)), "#{state} draws no #{word}"
      end
    end

    # A person who reads this screen across a room reads the block of colour first, so
    # the colour of a chip must not move with the track that plays.
    test "two tracks of the one state draw the one chip" do
      playing = %{Screen.new() | state: :playing, title: "The Detail"}

      assert chip(playing) == chip(%{playing | title: "Black Sheep", subtitle: "RNZ"})
    end

    defp chip(view) do
      Tree.find_by(
        Screen.render(view),
        &(&1.attrs[:background] == Style.state_colour(view.state))
      )
    end
  end

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

  defp pixel(pixels, width, x, y) do
    offset = (y * width + x) * 4
    <<_::binary-size(^offset), red, green, blue, _alpha, _rest::binary>> = pixels

    {red, green, blue}
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
