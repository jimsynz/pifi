defmodule MyHiFi.Peripheral.PiTft.Ili9341Test do
  use ExUnit.Case, async: false

  alias MyHiFi.Peripheral.PiTft.Ili9341
  alias MyHiFi.Test.RecordingScreen

  @memory_access_control 0x36
  @pixel_format_set 0x3A
  @column_address_set 0x2A
  @page_address_set 0x2B
  @memory_write 0x2C

  @screen_bus "spidev0.0"
  @display_on 0x29

  setup do
    RecordingScreen.use_it()
    {:ok, screen} = Ili9341.open(speed_hz: 32_000_000)
    RecordingScreen.forget()

    %{screen: screen}
  end

  describe "to_rgb565/1" do
    test "keeps the top bits of each channel and drops the alpha" do
      assert <<0xF8, 0x00>> == Ili9341.to_rgb565(<<255, 0, 0, 255>>)
      assert <<0x07, 0xE0>> == Ili9341.to_rgb565(<<0, 255, 0, 255>>)
      assert <<0x00, 0x1F>> == Ili9341.to_rgb565(<<0, 0, 255, 255>>)
      assert <<0xFF, 0xFF>> == Ili9341.to_rgb565(<<255, 255, 255, 0>>)
      assert <<0x00, 0x00>> == Ili9341.to_rgb565(<<0, 0, 0, 255>>)
    end

    test "gives two bytes for each four" do
      {width, height} = Ili9341.size()
      rgba = :binary.copy(<<1, 2, 3, 255>>, width * height)

      assert byte_size(Ili9341.to_rgb565(rgba)) == width * height * 2
    end
  end

  describe "open/1" do
    test "leaves the screen in 16 bit colour, turned around, and on" do
      RecordingScreen.use_it()
      {:ok, _screen} = Ili9341.open()

      commands = RecordingScreen.commands()

      assert {@pixel_format_set, <<0x55>>} in commands
      assert {@memory_access_control, <<0x28>>} in commands
      assert List.last(commands) == {@display_on, <<>>}
    end

    test "turns the screen the other way around when asked" do
      RecordingScreen.use_it()
      {:ok, _screen} = Ili9341.open(rotation: :landscape_inverted)

      assert {@memory_access_control, <<0xE8>>} in RecordingScreen.commands()
    end
  end

  describe "write_frame/2" do
    test "names the whole screen and then writes every pixel", %{screen: screen} do
      {width, height} = Ili9341.size()
      pixels = :binary.copy(<<0xF8, 0x00>>, width * height)

      assert :ok == Ili9341.write_frame(screen, pixels)

      assert [
               {@column_address_set, <<0::16, 319::16>>},
               {@page_address_set, <<0::16, 239::16>>},
               {@memory_write, written}
             ] = RecordingScreen.commands()

      assert written == pixels
    end

    test "writes in parts that the bus accepts", %{screen: screen} do
      {width, height} = Ili9341.size()
      pixels = :binary.copy(<<0xF8, 0x00>>, width * height)

      :ok = Ili9341.write_frame(screen, pixels)

      transfers = pixel_transfers()

      assert Enum.sum(transfers) == byte_size(pixels)
      assert Enum.max(transfers) <= 4096
      assert length(transfers) == ceil(byte_size(pixels) / 4096)
    end
  end

  describe "write_window/3" do
    test "names the part of the screen that it draws", %{screen: screen} do
      pixels = :binary.copy(<<0x07, 0xE0>>, 40 * 10)

      assert :ok == Ili9341.write_window(screen, {16, 200, 40, 10}, pixels)

      assert [
               {@column_address_set, <<16::16, 55::16>>},
               {@page_address_set, <<200::16, 209::16>>},
               {@memory_write, ^pixels}
             ] = RecordingScreen.commands()
    end
  end

  # Everything after the memory write command is a pixel, and the address payloads
  # before it are not.
  defp pixel_transfers do
    RecordingScreen.entries()
    |> Enum.drop_while(&(&1 != {:spi, @screen_bus, <<@memory_write>>}))
    |> Enum.drop(1)
    |> Enum.flat_map(fn
      {:spi, @screen_bus, data} -> [byte_size(data)]
      _other -> []
    end)
  end
end
