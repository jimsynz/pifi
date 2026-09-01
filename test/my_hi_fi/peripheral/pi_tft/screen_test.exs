defmodule MyHiFi.Peripheral.PiTft.ScreenTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Peripheral.PiTft.Screen

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
