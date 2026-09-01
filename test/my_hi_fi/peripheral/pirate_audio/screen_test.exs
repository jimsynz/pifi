defmodule MyHiFi.Peripheral.PirateAudio.ScreenTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Peripheral.PirateAudio.Screen

  describe "headline/1" do
    test "a track gives its title" do
      view = %{Screen.new() | state: :playing, title: "Tiny Ruins"}

      assert Screen.headline(view) == "Tiny Ruins"
    end

    test "a device that plays nothing names itself, so a person knows it is awake" do
      assert Screen.headline(Screen.new()) == "MyHiFi"
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
      }
    ]
  end
end
