defmodule MyHiFi.Peripheral.PiTft.Stmpe610 do
  @moduledoc """
  The STMPE610 of the PiTFT, over SPI.

  The chip reads the resistive touch panel, and it holds two GPIO lines of its own.
  **The backlight of this board is on GPIO 2 of this chip, and GPIO 18 of the
  Raspberry Pi reaches it on no board that this firmware drives.** The Adafruit
  PiTFT holds a solder jumper named `Lite #18` that joins the two, and the STMPE
  line takes precedence over that pin in any case. The clone that this firmware
  drives (Jaycar XC9022) holds no such jumper, so a write to pin 18 changes nothing
  at all: standby turned that pin low, the light stayed on, and the panel then slept
  and showed white under it.

  A measurement on 2026-09-01 on the board gave `0x0811` for the chip on
  `spidev0.1`, and a clear of GPIO 2 turned the light off.

  **Every clock of this chip is off until something turns them on.** `SYS_CTRL2`
  holds `0x0F` after a reset, and a write to a GPIO register then changes nothing.
  `open/1` writes `0x00` there before it touches a pin.

  The screen is on `spidev0.0` and this chip is on `spidev0.1`. The two share SPI0,
  so `MyHiFi.Peripheral.PiTft` owns both and no other process opens either. The
  reading of the touch panel comes next, and it belongs in this module.

  ## The exchanges

  Each exchange holds two bytes. A read sends the address with the high bit set and
  a byte for the answer to arrive in. A write sends the address and the value.
  """

  import Bitwise, only: [|||: 2]

  alias Circuits.SPI

  @chip_id 0x0811

  @chip_id_high 0x00
  @chip_id_low 0x01
  @system_control_1 0x03
  @system_control_2 0x04
  @gpio_set_pin 0x10
  @gpio_clear_pin 0x11
  @gpio_direction 0x13
  @gpio_alternate_function 0x17

  @read 0x80
  @soft_reset 0x02
  @clocks_on 0x00

  # GPIO 2 of the chip, as the bit that each GPIO register holds for it.
  @backlight 0x04

  @reset_delay_ms 10

  @typedoc "One STMPE610 that a caller holds."
  @type t :: %__MODULE__{bus: SPI.Bus.t()}

  defstruct [:bus]

  @doc """
  Take hold of the chip and turn the backlight on.

  ## Options

  - `:bus` - the SPI bus of the chip. `"spidev0.1"` by default.
  - `:speed_hz` - the bus speed. 500 kHz by default. The chip answers a read at that
    speed, and nothing here needs more.

  A bus that answers with another chip identifier gives
  `{:error, {:not_an_stmpe610, id}}` and holds no bus, because a board that answers
  something else holds its backlight somewhere else as well.
  """
  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts \\ []) do
    with {:ok, bus} <-
           SPI.open(Keyword.get(opts, :bus, "spidev0.1"),
             speed_hz: Keyword.get(opts, :speed_hz, 500_000),
             mode: 0
           ) do
      start(%__MODULE__{bus: bus})
    end
  end

  @doc "Turn the backlight on or off."
  @spec backlight(t(), boolean()) :: :ok | {:error, term()}
  def backlight(chip, true), do: write(chip, @gpio_set_pin, @backlight)
  def backlight(chip, false), do: write(chip, @gpio_clear_pin, @backlight)

  @doc "Give the chip back, and turn the backlight off with it."
  @spec close(t()) :: :ok
  def close(chip) do
    backlight(chip, false)
    SPI.close(chip.bus)
  end

  @doc "The identifier that the chip holds, which is `0x0811` for an STMPE610."
  @spec chip_id(t()) :: {:ok, 0..0xFFFF} | {:error, term()}
  def chip_id(chip) do
    with {:ok, high} <- read(chip, @chip_id_high),
         {:ok, low} <- read(chip, @chip_id_low) do
      {:ok, high * 256 + low}
    end
  end

  defp start(chip) do
    with {:ok, @chip_id} <- chip_id(chip),
         :ok <- write(chip, @system_control_1, @soft_reset),
         :ok <- sleep(@reset_delay_ms),
         :ok <- write(chip, @system_control_2, @clocks_on),
         :ok <- take_pin(chip, @gpio_alternate_function),
         :ok <- backlight(chip, true),
         :ok <- take_pin(chip, @gpio_direction) do
      {:ok, chip}
    else
      {:ok, other} -> stop(chip, {:not_an_stmpe610, other})
      {:error, reason} -> stop(chip, reason)
    end
  end

  defp stop(chip, reason) do
    SPI.close(chip.bus)
    {:error, reason}
  end

  # Each of these registers holds one bit for each pin, and the touch panel needs the
  # other pins, so this changes the bit of the backlight and leaves the rest as they
  # are. In `GPIO_ALT_FUNCT` the bit says that the pin is a GPIO, and in `GPIO_DIR` it
  # says that the pin drives a level.
  #
  # **The level goes in before the direction does.** The pin holds the light high
  # through a resistor of the board until this chip drives it, and the register of the
  # level holds 0 after a reset, so a direction that went first would turn the light
  # off for as long as the two writes take.
  defp take_pin(chip, register) do
    with {:ok, value} <- read(chip, register) do
      write(chip, register, value ||| @backlight)
    end
  end

  defp read(chip, register) do
    case SPI.transfer(chip.bus, <<register ||| @read, 0x00>>) do
      {:ok, <<_address, value>>} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write(chip, register, value), do: SPI.write(chip.bus, <<register, value>>)

  defp sleep(milliseconds) do
    Process.sleep(milliseconds)
    :ok
  end
end
