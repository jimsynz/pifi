defmodule MyHiFi.Peripheral.PiTft.ScreenTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Peripheral.PiTft.Screen
  alias MyHiFi.Test.Drawing

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
        |> Drawing.pixels(width, height, assets)

      assert {red, green, blue} = pixel(pixels, width, 160, 120)
      assert red < 40 and green < 40 and blue < 40
    end
  end

  # **A mark that is there at all is the signal**, and the colour says which fault. See
  # `MyHiFi.Screen.Network`.
  describe "the network" do
    test "a network that carries the music draws no mark" do
      assert marks(:internet) == %{amber: 0, rose: 0}
      assert marks(nil) == %{amber: 0, rose: 0}
    end

    # Amber is the colour of a device that is working on something. The radio link works
    # and a person looks at their router.
    test "a device with no way out of its network draws an amber mark" do
      assert %{amber: amber, rose: 0} = marks(:lan)
      assert amber > 0
    end

    # Rose is the colour of a fault, and it is the worse colour for the worse state.
    test "a device with no network at all draws a rose mark" do
      assert %{amber: 0, rose: rose} = marks(:disconnected)
      assert rose > 0
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
      context = splash_file(%{})

      view = %{
        Screen.new()
        | device_name: "Kitchen",
          splash_path: context.path,
          battery_percent: nil,
          network: :disconnected
      }

      assert %{rose: rose} = count(render_pixels(view, context.assets))
      assert rose > 0
    end

    defp marks(network) do
      view = %{
        Screen.new()
        | state: :playing,
          title: "Tiny Ruins",
          battery_percent: 94,
          network: network
      }

      count(render_pixels(view))
    end

    defp render_pixels(view, assets \\ []) do
      {width, height} = Screen.size()

      view
      |> Screen.render()
      |> Drawing.pixels(width, height, assets)
    end

    # **The mark is the one amber or rose thing at the top of the screen.** A state of
    # `:playing` draws an emerald pill, and a buffering one draws an amber pill, so
    # every view here plays.
    defp count(pixels) do
      {width, _height} = Screen.size()

      for y <- 8..40, x <- 0..(width - 1), reduce: %{amber: 0, rose: 0} do
        counted -> Map.update(counted, shade(pixel(pixels, width, x, y)), 1, &(&1 + 1))
      end
      |> Map.take([:amber, :rose])
    end

    # Amber 400 is `fbbf24` and rose 400 is `fb7185`. The green channel is what tells
    # them apart, and no other pixel of this strip holds a red channel that high.
    defp shade({red, green, blue}) when red > 220 and green > 160 and blue < 90, do: :amber
    defp shade({red, green, blue}) when red > 220 and green in 80..150 and blue > 100, do: :rose
    defp shade(_pixel), do: :other
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
  # the cache gives a thumbnail. See `MyHiFi.Screen.Renderer.assets/0`.
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
    |> Drawing.pixels(width, height)
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
