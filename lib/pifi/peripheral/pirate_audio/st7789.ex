defmodule PiFi.Peripheral.PirateAudio.St7789 do
  @moduledoc """
  The ST7789 screen of the Pimoroni Pirate Audio, over SPI.

  The screen has 240 by 240 pixels and it takes 16 bits for each one. It has no MISO
  line that this driver reads, so every exchange writes and the answer goes nowhere. A
  separate GPIO line says whether a byte is a command or the data of a command, and it
  is low for a command and high for data.

  A full frame is 115 200 bytes. `spidev` takes 4096 bytes in one transfer by default,
  so this asks `Circuits.SPI.max_transfer_size/1` and writes the frame in parts of that
  size.

  ## Two pins that surprise a reader

  **The data and command line is GPIO 9, which is MISO of SPI0.** The board uses that
  pin because the screen sends nothing back, so the line is free. Pimoroni reach it
  through `/dev/gpiomem`, which ignores the kernel, and `Circuits.GPIO` uses the
  character device instead, so the SPI driver could have held it. It does not: a
  measurement on the board on 2026-09-01 gave a handle on `gpiochip0` for
  `Circuits.GPIO.open(9, :output)`.

  **The screen is on chip select 1**, so the bus is `spidev0.1`. The PiTFT screen is on
  chip select 0, and a driver that took the default bus would talk to nothing here.

  ## The backlight

  It is GPIO 13 of the Raspberry Pi, and this module owns it, because nothing else on
  this board wants that pin. That is the difference from the PiTFT, where the light is a
  pin of the touch controller and `PiFi.Peripheral.PiTft.Stmpe610` owns it for that
  reason.

  **The order is the caller's, and it matters.** Wake the panel, draw a frame, and turn
  the light on after that, so a person never sees the frame that the panel held before.
  Going the other way, turn the light off first: a panel that sleeps under a light that
  is on shows white.

  ## The init sequence

  `@init_sequence` is the sequence of the Pimoroni `st7789-python` library, which is the
  software that ships with this board. **No part of it is measured here.** Most of it
  sets the power and the gamma of the panel, and a wrong gamma shows as a colour that is
  not the colour that Emerge drew.

  `@inversion_on` is not optional. The panel of this board is normally black, so a
  screen that never gets that command draws every colour the wrong way round. Pimoroni
  send it by default for the same reason.

  ## Which way the picture sits

  `:rotation` names the value of the memory access control register, and the four values
  turn the picture by a quarter each. **The screen is square, so every one of them
  draws, and only the orientation differs.**

  **0 is the value that this board needs**, measured on the board on 2026-09-01. A
  person read the screen at each of the four and named this one.

  Pimoroni hold this register at `0x70` and then turn the pixels themselves before they
  send them. This firmware turns nothing: a rotation in software would cost a pass over
  115 200 bytes for each frame, and the register does the same work for no cost. Their
  value therefore says nothing about the value that belongs here.

  **180 and 270 need a row offset that this driver does not hold.** Both set the row
  mirror bit, and the controller has 320 rows while the panel shows 240 of them, so a
  mirrored row 0 lands at row 319 and the picture sits 80 rows away from the glass. 0
  and 90 leave that bit clear and need no offset. Add the offset before you use the
  other two.
  """

  import Bitwise, only: [|||: 2]

  alias Circuits.GPIO
  alias Circuits.SPI

  @width 240
  @height 240

  @software_reset 0x01
  @sleep_in 0x10
  @sleep_out 0x11
  @inversion_on 0x21
  @display_off 0x28
  @display_on 0x29
  @column_address_set 0x2A
  @page_address_set 0x2B
  @memory_write 0x2C
  @memory_access_control 0x36
  @pixel_format_set 0x3A

  # 16 bits for each pixel on the interface that the processor writes. The ILI9341 of
  # the PiTFT takes 0x55 for the same thing, which sets the parallel interface as well,
  # and this panel has none.
  @sixteen_bits_per_pixel 0x05

  # Bit 5 exchanges the rows and the columns, and bit 6 and bit 7 mirror the two axes.
  # Bit 3 is clear, so the colour filter reads red, green and blue in that order. The
  # PiTFT needs that bit set and this panel does not.
  @row_column_exchange 0x20
  @column_mirror 0x40
  @row_mirror 0x80

  # The reset needs 150 ms. The panel then needs 120 ms after a sleep out before it
  # takes another command, and 100 ms after the display comes on.
  @reset_delay_ms 150
  @sleep_out_delay_ms 120
  @display_on_delay_ms 100

  @init_sequence [
    {0xB2, <<0x0C, 0x0C, 0x00, 0x33, 0x33>>},
    {0xB7, <<0x14>>},
    {0xBB, <<0x37>>},
    {0xC0, <<0x2C>>},
    {0xC2, <<0x01>>},
    {0xC3, <<0x12>>},
    {0xC4, <<0x20>>},
    {0xD0, <<0xA4, 0xA1>>},
    {0xC6, <<0x0F>>},
    {0xE0,
     <<0xD0, 0x04, 0x0D, 0x11, 0x13, 0x2B, 0x3F, 0x54, 0x4C, 0x18, 0x0D, 0x0B, 0x1F, 0x23>>},
    {0xE1, <<0xD0, 0x04, 0x0C, 0x11, 0x13, 0x2C, 0x3F, 0x44, 0x51, 0x2F, 0x1F, 0x1F, 0x20, 0x23>>}
  ]

  @typedoc "How far round the picture turns, in degrees."
  @type rotation :: 0 | 90 | 180 | 270

  @typedoc "One open screen, and the light that shines through it."
  @type t :: %__MODULE__{
          bus: SPI.Bus.t(),
          data_command: GPIO.Handle.t(),
          backlight: GPIO.Handle.t(),
          max_transfer: pos_integer()
        }

  defstruct [:bus, :data_command, :backlight, :max_transfer]

  @doc "The size of this screen, in pixels."
  @spec size() :: {pos_integer(), pos_integer()}
  def size, do: {@width, @height}

  @doc """
  Take hold of the screen and make it ready to draw.

  The backlight stays off, so the caller draws a frame before a person can see one.

  ## Options

  - `:bus` - the SPI bus of the screen. `"spidev0.1"` by default, which is chip
    select 1.
  - `:data_command` - the GPIO that says command or data. 9 by default.
  - `:backlight` - the GPIO of the backlight. 13 by default.
  - `:speed_hz` - the bus speed. 32 MHz by default, which writes a full frame in about
    29 ms. Pimoroni drive this board at 80 MHz.
  - `:rotation` - see `t:rotation/0`. 0 by default, which is what this board needs.
  """
  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts \\ []) do
    with {:ok, bus} <-
           SPI.open(Keyword.get(opts, :bus, "spidev0.1"),
             speed_hz: Keyword.get(opts, :speed_hz, 32_000_000)
           ),
         {:ok, data_command} <-
           GPIO.open(Keyword.get(opts, :data_command, 9), :output, initial_value: 0),
         {:ok, backlight} <-
           GPIO.open(Keyword.get(opts, :backlight, 13), :output, initial_value: 0) do
      screen = %__MODULE__{
        bus: bus,
        data_command: data_command,
        backlight: backlight,
        max_transfer: SPI.max_transfer_size(bus)
      }

      reset(screen, Keyword.get(opts, :rotation, 0))
    end
  end

  @doc "Turn the backlight on, or off."
  @spec backlight(t(), boolean()) :: :ok | {:error, term()}
  def backlight(screen, true), do: GPIO.write(screen.backlight, 1)
  def backlight(screen, false), do: GPIO.write(screen.backlight, 0)

  @doc "Give the screen back, and turn the backlight off with it."
  @spec close(t()) :: :ok
  def close(screen) do
    backlight(screen, false)
    GPIO.close(screen.backlight)
    GPIO.close(screen.data_command)
    SPI.close(screen.bus)
  end

  @doc """
  Wake the panel, or put it to sleep.

  A panel that sleeps draws nothing and keeps no frame, and it needs 120 ms to wake.
  `PiFi.Peripheral.PirateAudio` does this for standby, because a screen that stayed
  lit would tell a person that the device is awake.

  **The backlight is not part of this**, so that a caller can keep the order. See the
  moduledoc.
  """
  @spec display(t(), boolean()) :: :ok | {:error, term()}
  def display(screen, true) do
    with :ok <- command(screen, @sleep_out),
         :ok <- sleep(@sleep_out_delay_ms) do
      command(screen, @display_on)
    end
  end

  def display(screen, false) do
    with :ok <- command(screen, @display_off) do
      command(screen, @sleep_in)
    end
  end

  @doc """
  Turn RGBA into RGB565, with the high byte first.

  `PiFi.Screen.Renderer` gives four bytes for each pixel, and this keeps the
  top 5, 6 and 5 bits and drops the alpha. The screen draws no transparency, so nothing
  is lost.
  """
  @spec to_rgb565(binary()) :: binary()
  def to_rgb565(rgba) do
    for <<red::5, _::3, green::6, _::2, blue::5, _::3, _alpha::8 <- rgba>>,
      into: <<>>,
      do: <<red::5, green::6, blue::5>>
  end

  @doc """
  Draw one frame.

  The pixels are RGB565 for the whole screen, which is 115 200 bytes.
  """
  @spec write_frame(t(), binary()) :: :ok | {:error, term()}
  def write_frame(screen, pixels), do: write_window(screen, {0, 0, @width, @height}, pixels)

  @doc """
  Draw one part of the screen.

  The window is `{x, y, width, height}`, and the pixels are RGB565 for that window
  alone.
  """
  @spec write_window(
          t(),
          {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()},
          binary()
        ) :: :ok | {:error, term()}
  def write_window(screen, {x, y, width, height}, pixels) do
    with :ok <- command(screen, @column_address_set, <<x::16, x + width - 1::16>>),
         :ok <- command(screen, @page_address_set, <<y::16, y + height - 1::16>>),
         :ok <- command(screen, @memory_write) do
      data(screen, pixels)
    end
  end

  defp reset(screen, rotation) do
    with :ok <- command(screen, @software_reset),
         :ok <- sleep(@reset_delay_ms),
         :ok <- command(screen, @memory_access_control, <<memory_access(rotation)>>),
         :ok <- command(screen, @pixel_format_set, <<@sixteen_bits_per_pixel>>),
         :ok <- Enum.reduce_while(@init_sequence, :ok, &init_step(screen, &1, &2)),
         :ok <- command(screen, @inversion_on),
         :ok <- command(screen, @sleep_out),
         :ok <- sleep(@sleep_out_delay_ms),
         :ok <- command(screen, @display_on),
         :ok <- sleep(@display_on_delay_ms) do
      {:ok, screen}
    end
  end

  defp init_step(screen, {command, payload}, _acc) do
    case command(screen, command, payload) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp memory_access(0), do: 0x00
  defp memory_access(90), do: @row_column_exchange ||| @column_mirror
  defp memory_access(180), do: @column_mirror ||| @row_mirror
  defp memory_access(270), do: @row_column_exchange ||| @row_mirror

  defp command(screen, command, payload \\ <<>>) do
    with :ok <- GPIO.write(screen.data_command, 0),
         {:ok, _read} <- SPI.transfer(screen.bus, <<command>>) do
      data(screen, payload)
    end
  end

  defp data(_screen, <<>>), do: :ok

  defp data(screen, payload) do
    with :ok <- GPIO.write(screen.data_command, 1) do
      payload
      |> chunk(screen.max_transfer)
      |> Enum.reduce_while(:ok, &transfer_chunk(screen, &1, &2))
    end
  end

  defp transfer_chunk(screen, chunk, _acc) do
    case SPI.transfer(screen.bus, chunk) do
      {:ok, _read} -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp chunk(payload, size) when byte_size(payload) <= size, do: [payload]

  defp chunk(payload, size) do
    <<head::binary-size(^size), rest::binary>> = payload
    [head | chunk(rest, size)]
  end

  defp sleep(milliseconds) do
    Process.sleep(milliseconds)
    :ok
  end
end
