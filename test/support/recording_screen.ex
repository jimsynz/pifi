defmodule MyHiFi.Test.RecordingScreen do
  @moduledoc """
  A Circuits SPI bus and a Circuits GPIO line that write down what they get.

  `MyHiFi.Peripheral.PiTft.Ili9341` drives a screen over SPI, and the host of a
  developer holds no such screen. `Circuits.SPI.NilBackend` is what a host gets, and
  its `open/2` gives `{:error, :unimplemented}`, so it drives no test.

  This module gives both backends instead. They record into one list, in the order
  that they were called, so a test proves the thing that matters: the data or
  command line holds the correct level for each byte that follows it.

      MyHiFi.Test.RecordingScreen.use_it()
      {:ok, screen} = Ili9341.open()
      assert {:command, 0x2C, _} = ...MyHiFi.Test.RecordingScreen.commands()

  The recorder is a named process, so a test that uses it is not `async`.
  """

  use Agent

  # The PiTFT screen is on one bus of SPI0 and its touch controller is on the other, and
  # the backlight is GPIO 2 of that controller. See `MyHiFi.Peripheral.PiTft.Stmpe610`.
  # The Pirate Audio puts its screen on the other bus, its data and command line on GPIO
  # 9, and its backlight on a line of the Raspberry Pi, so `use_it/1` takes all three.
  @pi_tft [screen_bus: "spidev0.0", data_command: 25, backlight_line: nil]
  @gpio_set_pin 0x10
  @gpio_clear_pin 0x11

  @doc """
  Start the recorder and make these the Circuits backends for one test.

  ## Options

  - `:screen_bus` - the SPI bus that the screen is on. `"spidev0.0"` by default, which
    is the PiTFT. The Pirate Audio is on `"spidev0.1"`.
  - `:data_command` - the GPIO that says command or data. 25 by default, which is the
    PiTFT. The Pirate Audio uses 9.
  - `:backlight_line` - the GPIO of the backlight, for a board that holds it on a line
    of the Raspberry Pi. `nil` by default, because the PiTFT holds it on the touch
    controller instead. See `backlight/0` and `backlight_line/0`.
  """
  @spec use_it(keyword()) :: :ok
  def use_it(opts \\ []) do
    start_link([])
    Agent.update(__MODULE__, fn state -> %{state | config: Keyword.merge(@pi_tft, opts)} end)

    Application.put_env(:circuits_spi, :default_backend, __MODULE__.Spi)
    Application.put_env(:circuits_gpio, :default_backend, __MODULE__.Gpio)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:circuits_spi, :default_backend)
      Application.delete_env(:circuits_gpio, :default_backend)
    end)
  end

  @doc false
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts),
    do: Agent.start_link(fn -> %{entries: [], config: @pi_tft} end, name: __MODULE__)

  @typedoc "One thing that the driver did."
  @type entry :: {:spi, String.t(), binary()} | {:gpio, 0 | 1} | {:backlight, 0 | 1}

  @doc "What `use_it/1` was told about the board under test."
  @spec config() :: keyword()
  def config, do: Agent.get(__MODULE__, & &1.config)

  @doc "Write one entry down. The backends call this."
  @spec record(entry()) :: :ok
  def record(entry), do: Agent.update(__MODULE__, &%{&1 | entries: [entry | &1.entries]})

  @doc "Everything that happened, in order."
  @spec entries() :: [entry()]
  def entries, do: __MODULE__ |> Agent.get(& &1.entries) |> Enum.reverse()

  @doc """
  The levels that the backlight was given, in order.

  1 is on and 0 is off. The backlight is GPIO 2 of the STMPE610, so each level here
  is a write of `GPIO_SET_PIN` or `GPIO_CLR_PIN` on the bus of that chip. See
  `MyHiFi.Peripheral.PiTft.Stmpe610`.
  """
  @spec backlight() :: [0 | 1]
  def backlight do
    touch_bus = other_bus()

    for {:spi, ^touch_bus, <<register, 0x04>>} <- entries(),
        register in [@gpio_set_pin, @gpio_clear_pin],
        do: if(register == @gpio_set_pin, do: 1, else: 0)
  end

  @doc """
  The levels that a backlight on a line of the Raspberry Pi was given, in order.

  1 is on and 0 is off. This is the Pirate Audio, where the light is GPIO 13 of the
  board. The PiTFT holds its light on the touch controller, so it uses `backlight/0`
  instead. See `MyHiFi.Peripheral.PirateAudio.St7789`.
  """
  @spec backlight_line() :: [0 | 1]
  def backlight_line, do: for({:backlight, level} <- entries(), do: level)

  @doc "Forget everything, so a test reads one draw and not the init sequence too."
  @spec forget() :: :ok
  def forget, do: Agent.update(__MODULE__, &%{&1 | entries: []})

  @doc """
  What the screen was told, as commands.

  Each entry is `{command_byte, payload}`. The payload holds every byte that the
  driver sent with the line high, joined, so a frame that went out in parts reads as
  one binary.

  A byte that arrives with the line high and no command before it means that the
  driver did not set the line, and this raises for that.
  """
  @spec commands() :: [{byte(), binary()}]
  def commands do
    bus = screen_bus()

    entries()
    |> Enum.reduce({nil, []}, &fold(bus, &1, &2))
    |> flush()
    |> Enum.reverse()
  end

  defp screen_bus, do: Keyword.fetch!(config(), :screen_bus)

  # The PiTFT holds its touch controller on the bus that the screen is not on.
  defp other_bus do
    case screen_bus() do
      "spidev0.0" -> "spidev0.1"
      _other -> "spidev0.0"
    end
  end

  # The backlight of a line is not a byte of the screen, so it ends no command.
  defp fold(_bus, {:backlight, _level}, state), do: state

  # The line goes low for a command, so a low level ends the command before it.
  defp fold(_bus, {:gpio, 0}, state), do: {:awaiting_command, flush(state)}

  # The line goes high for data, and the bytes that follow belong to the command
  # that is already open.
  defp fold(_bus, {:gpio, 1}, state), do: state

  defp fold(bus, {:spi, bus, <<command>>}, {:awaiting_command, commands}),
    do: {{command, []}, commands}

  defp fold(bus, {:spi, bus, payload}, {{command, parts}, commands}),
    do: {{command, [payload | parts]}, commands}

  defp fold(bus, {:spi, bus, payload}, {:awaiting_command, _commands}) do
    raise "a command is one byte, and the screen got #{byte_size(payload)} with the line low"
  end

  defp fold(bus, {:spi, bus, payload}, {nil, _commands}) do
    raise "the screen got #{byte_size(payload)} bytes before the line said command or data"
  end

  # Anything on the other bus says nothing about the screen.
  defp fold(_bus, {:spi, _other, _data}, state), do: state

  defp flush({{command, parts}, commands}),
    do: [{command, parts |> Enum.reverse() |> IO.iodata_to_binary()} | commands]

  defp flush({_nothing_open, commands}), do: commands

  defmodule Spi do
    @moduledoc "The SPI backend of `MyHiFi.Test.RecordingScreen`."

    @behaviour Circuits.SPI.Backend

    defstruct [:name, max_transfer_size: 4096]

    @impl Circuits.SPI.Backend
    def bus_names(_options), do: ["spidev0.0", "spidev0.1"]

    @impl Circuits.SPI.Backend
    def open(bus_name, options) do
      {:ok,
       %__MODULE__{
         name: bus_name,
         max_transfer_size: Keyword.get(options, :max_transfer_size, 4096)
       }}
    end

    @impl Circuits.SPI.Backend
    def info, do: %{name: __MODULE__}

    defimpl Circuits.SPI.Bus do
      alias MyHiFi.Test.RecordingScreen

      def config(_bus), do: {:ok, %{mode: 0, bits_per_word: 8, speed_hz: 32_000_000, delay_us: 0}}

      def transfer(bus, data) do
        data = IO.iodata_to_binary(data)
        RecordingScreen.record({:spi, bus.name, data})
        {:ok, answer(data)}
      end

      # The STMPE610 reads its identifier before it takes the backlight pin, so this
      # answers `0x0811` for those two addresses. Every other read gives zeros, as the
      # screen does: it holds no MISO line that the driver reads.
      defp answer(<<0x80, _dummy>>), do: <<0x00, 0x08>>
      defp answer(<<0x81, _dummy>>), do: <<0x00, 0x11>>
      defp answer(data), do: :binary.copy(<<0>>, byte_size(data))

      def write(bus, data) do
        {:ok, _read} = transfer(bus, data)
        :ok
      end

      def read(bus, length), do: transfer(bus, :binary.copy(<<0>>, length))

      def close(_bus), do: :ok

      def max_transfer_size(bus), do: bus.max_transfer_size
    end
  end

  defmodule Gpio do
    @moduledoc "The GPIO backend of `MyHiFi.Test.RecordingScreen`."

    @behaviour Circuits.GPIO.Backend

    defstruct [:spec]

    @impl Circuits.GPIO.Backend
    def enumerate(_options), do: []

    @impl Circuits.GPIO.Backend
    def identifiers(spec, _options),
      do: {:ok, %{location: {"gpiochip0", spec}, label: "recording", controller: "gpiochip0"}}

    @impl Circuits.GPIO.Backend
    def status(_spec, _options),
      do: {:ok, %{direction: :output, pull_mode: :none, drive_mode: :push_pull}}

    @impl Circuits.GPIO.Backend
    def open(spec, _direction, _options), do: {:ok, %__MODULE__{spec: spec}}

    @impl Circuits.GPIO.Backend
    def force_close(_spec, _options), do: :ok

    @impl Circuits.GPIO.Backend
    def backend_info, do: %{name: __MODULE__}

    defimpl Circuits.GPIO.Handle do
      alias MyHiFi.Test.RecordingScreen

      # Which line says command or data, and which one carries the backlight, depends on
      # the board. The PiTFT holds its light on the touch controller and names no line
      # here. See `MyHiFi.Test.RecordingScreen.use_it/1`.
      def write(%{spec: spec}, value) do
        config = RecordingScreen.config()

        cond do
          spec == Keyword.fetch!(config, :data_command) ->
            RecordingScreen.record({:gpio, value})

          spec == Keyword.get(config, :backlight_line) ->
            RecordingScreen.record({:backlight, value})

          true ->
            :ok
        end
      end

      def read(_handle), do: 0
      def status(_handle), do: {:ok, %{direction: :output}}
      def set_direction(_handle, _direction), do: :ok
      def set_pull_mode(_handle, _mode), do: :ok
      def set_drive_mode(_handle, _mode), do: :ok
      def close(_handle), do: :ok
      def set_interrupts(_handle, _trigger, _options), do: :ok
      def subscribe(_handle, _options), do: {:ok, make_ref()}
      def unsubscribe(_handle), do: :ok
    end
  end
end
