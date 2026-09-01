defmodule MyHiFi.Peripheral.PirateAudio.St7789Test do
  use ExUnit.Case, async: false

  alias MyHiFi.Peripheral.PirateAudio.St7789
  alias MyHiFi.Test.RecordingScreen

  @memory_access_control 0x36
  @pixel_format_set 0x3A
  @column_address_set 0x2A
  @page_address_set 0x2B
  @memory_write 0x2C
  @inversion_on 0x21
  @sleep_in 0x10
  @sleep_out 0x11
  @display_off 0x28
  @display_on 0x29

  @board [screen_bus: "spidev0.1", data_command: 9, backlight_line: 13]

  setup do
    RecordingScreen.use_it(@board)
    {:ok, screen} = St7789.open()
    RecordingScreen.forget()

    %{screen: screen}
  end

  describe "to_rgb565/1" do
    test "keeps the top bits of each channel and drops the alpha" do
      assert <<0xF8, 0x00>> == St7789.to_rgb565(<<255, 0, 0, 255>>)
      assert <<0x07, 0xE0>> == St7789.to_rgb565(<<0, 255, 0, 255>>)
      assert <<0x00, 0x1F>> == St7789.to_rgb565(<<0, 0, 255, 255>>)
      assert <<0x00, 0x00>> == St7789.to_rgb565(<<0, 0, 0, 255>>)
    end

    test "gives two bytes for each four" do
      {width, height} = St7789.size()
      rgba = :binary.copy(<<1, 2, 3, 255>>, width * height)

      assert byte_size(St7789.to_rgb565(rgba)) == width * height * 2
    end
  end

  describe "open/1" do
    test "leaves the screen in 16 bit colour, inverted, and on" do
      RecordingScreen.use_it(@board)
      {:ok, _screen} = St7789.open()

      commands = RecordingScreen.commands()

      assert {@pixel_format_set, <<0x05>>} in commands
      assert {@inversion_on, <<>>} in commands
      assert List.last(commands) == {@display_on, <<>>}
    end

    # The panel of this board is normally black, so a screen that never gets this draws
    # every colour the wrong way round.
    test "the inversion comes before the panel wakes, so no frame shows the wrong way" do
      RecordingScreen.use_it(@board)
      {:ok, _screen} = St7789.open()

      sent = Enum.map(RecordingScreen.commands(), fn {command, _payload} -> command end)

      assert Enum.find_index(sent, &(&1 == @inversion_on)) <
               Enum.find_index(sent, &(&1 == @sleep_out))
    end

    test "each quarter turn names its own value of the memory access register" do
      for {rotation, value} <- [{0, 0x00}, {90, 0x60}, {180, 0xC0}, {270, 0xA0}] do
        RecordingScreen.use_it(@board)
        {:ok, _screen} = St7789.open(rotation: rotation)

        assert {@memory_access_control, <<value>>} in RecordingScreen.commands()
      end
    end

    # A person must never see the frame that the panel held before the device lost its
    # power, so the light waits for the caller to draw one.
    test "the backlight stays off, so the caller draws before a person can see" do
      RecordingScreen.use_it(@board)
      {:ok, _screen} = St7789.open()

      refute 1 in RecordingScreen.backlight_line()
    end
  end

  describe "backlight/2" do
    test "turns the light on and off", %{screen: screen} do
      :ok = St7789.backlight(screen, true)
      :ok = St7789.backlight(screen, false)

      assert RecordingScreen.backlight_line() == [1, 0]
    end
  end

  describe "display/2" do
    test "a sleep turns the panel off and then puts it to sleep", %{screen: screen} do
      :ok = St7789.display(screen, false)

      assert [{@display_off, <<>>}, {@sleep_in, <<>>}] = RecordingScreen.commands()
    end

    test "a wake takes the panel out of sleep and then turns it on", %{screen: screen} do
      :ok = St7789.display(screen, true)

      assert [{@sleep_out, <<>>}, {@display_on, <<>>}] = RecordingScreen.commands()
    end
  end

  describe "write_frame/2" do
    test "names the whole screen and then writes the pixels", %{screen: screen} do
      {width, height} = St7789.size()
      pixels = :binary.copy(<<0xAB, 0xCD>>, width * height)

      :ok = St7789.write_frame(screen, pixels)

      assert [
               {@column_address_set, <<0::16, 239::16>>},
               {@page_address_set, <<0::16, 239::16>>},
               {@memory_write, ^pixels}
             ] = RecordingScreen.commands()
    end

    # A frame is 115 200 bytes and `spidev` takes 4096 in one transfer, so the driver
    # asks the bus for its limit and never holds a constant of its own.
    test "goes out in parts that the bus accepts", %{screen: screen} do
      {width, height} = St7789.size()
      pixels = :binary.copy(<<0xAB, 0xCD>>, width * height)

      :ok = St7789.write_frame(screen, pixels)

      # The window commands carry four bytes each, so a count of every write that is not
      # one byte would take those as well. The pixels are what follows the memory write.
      sizes =
        RecordingScreen.entries()
        |> Enum.drop_while(&(&1 != {:spi, "spidev0.1", <<@memory_write>>}))
        |> Enum.drop(1)
        |> Enum.flat_map(fn
          {:spi, "spidev0.1", data} -> [byte_size(data)]
          _other -> []
        end)

      assert Enum.sum(sizes) == width * height * 2
      assert Enum.all?(sizes, &(&1 <= 4096))
    end
  end

  describe "write_window/3" do
    test "names the part that it draws", %{screen: screen} do
      pixels = :binary.copy(<<0xAB, 0xCD>>, 10 * 4)

      :ok = St7789.write_window(screen, {5, 6, 10, 4}, pixels)

      assert [
               {@column_address_set, <<5::16, 14::16>>},
               {@page_address_set, <<6::16, 9::16>>},
               {@memory_write, ^pixels}
             ] = RecordingScreen.commands()
    end
  end
end
