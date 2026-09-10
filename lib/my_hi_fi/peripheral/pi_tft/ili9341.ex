defmodule MyHiFi.Peripheral.PiTft.Ili9341 do
  @moduledoc """
  The ILI9341 screen of the PiTFT, over SPI.

  The screen has 320 by 240 pixels and it takes 16 bits for each one. It has no
  MISO line that this driver reads, so every exchange writes and the answer goes
  nowhere.

  A separate GPIO line says whether a byte is a command or the data of a command.
  The line is low for a command and high for data, so each write sets it first.

  ## The pixels

  `write_frame/2` takes RGB565 in the order that `to_rgb565/1` gives, which is the
  high byte first. `to_rgb565/1` takes the RGBA that
  `EmergeSkia.render_to_pixels/2` gives and keeps the top bits of each channel.

  A full frame is 153 600 bytes. `spidev` takes 4096 bytes in one transfer by
  default, and the limit is a module parameter of the driver, so this asks
  `Circuits.SPI.max_transfer_size/1` and writes the frame in parts of that size. It
  names no constant for the limit.

  ## The init sequence

  `@init_sequence` is the sequence of the Adafruit driver, and most of it sets the
  power and the gamma of the panel. **No part of it is measured on this board.**
  The panel of a clone may need other values, and a wrong gamma shows as a colour
  that is not the colour that Emerge drew. A clone may also hold a controller that
  is not an ILI9341, so read the parts of the board before you change a value here.
  """

  import Bitwise, only: [|||: 2]

  alias Circuits.GPIO
  alias Circuits.SPI

  @width 320
  @height 240

  @software_reset 0x01
  @sleep_in 0x10
  @sleep_out 0x11
  @display_off 0x28
  @display_on 0x29
  @column_address_set 0x2A
  @page_address_set 0x2B
  @memory_write 0x2C
  @memory_access_control 0x36
  @pixel_format_set 0x3A

  @sixteen_bits_per_pixel 0x55

  # Bit 5 turns the rows and the columns around, which is what makes the panel 320
  # by 240 and not 240 by 320. Bit 6 and bit 7 mirror the two axes, and which one a
  # board needs depends on the way that the screen sits in its case. Bit 3 says that
  # the colour filter of the panel is BGR, which is what this panel has.
  @row_column_exchange 0x20
  @column_mirror 0x40
  @row_mirror 0x80
  @bgr_filter 0x08

  # The reset needs 5 ms, and the panel needs 120 ms after it before it takes a
  # sleep out. The datasheet asks for both.
  @reset_delay_ms 150
  @sleep_out_delay_ms 120

  @init_sequence [
    {0xEF, <<0x03, 0x80, 0x02>>},
    {0xCF, <<0x00, 0xC1, 0x30>>},
    {0xED, <<0x64, 0x03, 0x12, 0x81>>},
    {0xE8, <<0x85, 0x00, 0x78>>},
    {0xCB, <<0x39, 0x2C, 0x00, 0x34, 0x02>>},
    {0xF7, <<0x20>>},
    {0xEA, <<0x00, 0x00>>},
    {0xC0, <<0x23>>},
    {0xC1, <<0x10>>},
    {0xC5, <<0x3E, 0x28>>},
    {0xC7, <<0x86>>},
    {0xB1, <<0x00, 0x18>>},
    {0xB6, <<0x08, 0x82, 0x27>>},
    {0xF2, <<0x00>>},
    {0x26, <<0x01>>},
    {0xE0,
     <<0x0F, 0x31, 0x2B, 0x0C, 0x0E, 0x08, 0x4E, 0xF1, 0x37, 0x07, 0x10, 0x03, 0x0E, 0x09, 0x00>>},
    {0xE1,
     <<0x00, 0x0E, 0x14, 0x03, 0x11, 0x07, 0x31, 0xC1, 0x48, 0x08, 0x0F, 0x0C, 0x31, 0x36, 0x0F>>}
  ]

  @typedoc "The way that the screen sits. Both give 320 by 240."
  @type rotation :: :landscape | :landscape_inverted

  @typedoc "One open screen."
  @type t :: %__MODULE__{
          bus: SPI.Bus.t(),
          data_command: GPIO.Handle.t(),
          max_transfer: pos_integer()
        }

  defstruct [:bus, :data_command, :max_transfer]

  @doc "The size of this screen, in pixels."
  @spec size() :: {pos_integer(), pos_integer()}
  def size, do: {@width, @height}

  @doc """
  Take hold of the screen and make it ready to draw.

  ## Options

  - `:bus` - the SPI bus of the screen. `"spidev0.0"` by default.
  - `:data_command` - the GPIO that says command or data. 25 by default.
  - `:speed_hz` - the bus speed. 32 MHz by default, which writes a full frame in
    38 ms.
  - `:rotation` - see `t:rotation/0`. `:landscape` by default.
  """
  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts \\ []) do
    with {:ok, bus} <-
           SPI.open(Keyword.get(opts, :bus, "spidev0.0"),
             speed_hz: Keyword.get(opts, :speed_hz, 32_000_000)
           ),
         {:ok, data_command} <-
           GPIO.open(Keyword.get(opts, :data_command, 25), :output, initial_value: 0) do
      screen = %__MODULE__{
        bus: bus,
        data_command: data_command,
        max_transfer: SPI.max_transfer_size(bus)
      }

      reset(screen, Keyword.get(opts, :rotation, :landscape))
    end
  end

  @doc "Give the screen back."
  @spec close(t()) :: :ok
  def close(screen) do
    GPIO.close(screen.data_command)
    SPI.close(screen.bus)
  end

  @doc """
  Wake the panel, or put it to sleep.

  A panel that sleeps draws nothing and keeps no frame, and it needs 120 ms to wake.
  `MyHiFi.Peripheral.PiTft` does this for standby, because a screen that stayed lit
  would tell a person that the device is awake.

  **The backlight is not part of this, and the order is the reason.** A caller wakes
  the panel, draws a frame, and turns the backlight on after that, so a person never
  sees the frame that the panel held before. Going the other way it turns the light
  off first, because a panel that sleeps under a light that is on shows white. The
  light is on the touch controller. See `MyHiFi.Peripheral.PiTft.Stmpe610`.
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

  `EmergeSkia.render_to_pixels/2` gives four bytes for each pixel, and this keeps
  the top 5, 6 and 5 bits and drops the alpha. The screen draws no transparency, so
  nothing is lost.
  """
  @spec to_rgb565(binary()) :: binary()
  def to_rgb565(rgba) do
    for <<red::5, _::3, green::6, _::2, blue::5, _::3, _alpha::8 <- rgba>>,
      into: <<>>,
      do: <<red::5, green::6, blue::5>>
  end

  @doc """
  Draw one frame.

  The pixels are RGB565 for the whole screen, which is 153 600 bytes.
  """
  @spec write_frame(t(), binary()) :: :ok | {:error, term()}
  def write_frame(screen, pixels), do: write_window(screen, {0, 0, @width, @height}, pixels)

  @doc """
  Draw one part of the screen.

  The window is `{x, y, width, height}`, and the pixels are RGB565 for that window
  alone. A window costs less than a frame, so a change of the time needs the rows
  that hold the time and no more.
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
         :ok <- Enum.reduce_while(@init_sequence, :ok, &init_step(screen, &1, &2)),
         :ok <- command(screen, @memory_access_control, <<memory_access(rotation)>>),
         :ok <- command(screen, @pixel_format_set, <<@sixteen_bits_per_pixel>>),
         :ok <- command(screen, @sleep_out),
         :ok <- sleep(@sleep_out_delay_ms),
         :ok <- command(screen, @display_on) do
      {:ok, screen}
    end
  end

  defp init_step(screen, {command, payload}, _acc) do
    case command(screen, command, payload) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp memory_access(:landscape), do: @row_column_exchange ||| @bgr_filter

  defp memory_access(:landscape_inverted),
    do: @row_column_exchange ||| @column_mirror ||| @row_mirror ||| @bgr_filter

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
