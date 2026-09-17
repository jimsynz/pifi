defmodule PiFi.Peripheral.PiTft.Stmpe610Test do
  # `PiFi.Test.RecordingScreen` is a named process, so two of these cannot run at
  # the same time.
  use ExUnit.Case, async: false

  alias PiFi.Peripheral.PiTft.Stmpe610
  alias PiFi.Test.RecordingScreen

  @system_control_1 0x03
  @system_control_2 0x04
  @gpio_set_pin 0x10
  @gpio_clear_pin 0x11
  @gpio_direction 0x13
  @gpio_alternate_function 0x17

  @soft_reset 0x02
  @clocks_on 0x00
  @backlight 0x04

  setup do
    RecordingScreen.use_it()
    :ok
  end

  # Each write holds the address and the value, and a read holds the high bit of the
  # address, so this passes the reads by.
  defp writes do
    for {:spi, "spidev0.1", <<register, value>>} <- RecordingScreen.entries(),
        register < 0x80,
        do: {register, value}
  end

  describe "open/1" do
    # Every clock of this chip is off after a reset, and a write to a GPIO register
    # then changes nothing at all, so `SYS_CTRL2` comes before the two pin registers.
    # The level of the pin goes in before the direction, so the light stays on while
    # this chip takes hold of it.
    test "it resets the chip, turns the clocks on, and then takes the pin" do
      {:ok, _chip} = Stmpe610.open()

      assert writes() == [
               {@system_control_1, @soft_reset},
               {@system_control_2, @clocks_on},
               {@gpio_alternate_function, @backlight},
               {@gpio_set_pin, @backlight},
               {@gpio_direction, @backlight}
             ]
    end

    test "it leaves the backlight on" do
      {:ok, _chip} = Stmpe610.open()

      assert List.last(RecordingScreen.backlight()) == 1
    end
  end

  describe "backlight/2" do
    test "it sets the pin for on and clears it for off" do
      {:ok, chip} = Stmpe610.open()
      RecordingScreen.forget()

      :ok = Stmpe610.backlight(chip, false)
      :ok = Stmpe610.backlight(chip, true)

      assert writes() == [{@gpio_clear_pin, @backlight}, {@gpio_set_pin, @backlight}]
      assert RecordingScreen.backlight() == [0, 1]
    end
  end

  describe "close/1" do
    test "it turns the backlight off before it gives the bus back" do
      {:ok, chip} = Stmpe610.open()
      RecordingScreen.forget()

      assert :ok = Stmpe610.close(chip)

      assert RecordingScreen.backlight() == [0]
    end
  end

  describe "chip_id/1" do
    test "it reads the identifier that an STMPE610 holds" do
      {:ok, chip} = Stmpe610.open()

      assert Stmpe610.chip_id(chip) == {:ok, 0x0811}
    end
  end
end
