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

  @doc "Start the recorder and make these the Circuits backends for one test."
  @spec use_it() :: :ok
  def use_it do
    start_link([])

    Application.put_env(:circuits_spi, :default_backend, __MODULE__.Spi)
    Application.put_env(:circuits_gpio, :default_backend, __MODULE__.Gpio)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:circuits_spi, :default_backend)
      Application.delete_env(:circuits_gpio, :default_backend)
    end)
  end

  @doc false
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  @typedoc "One thing that the driver did."
  @type entry :: {:spi, binary()} | {:gpio, 0 | 1} | {:backlight, 0 | 1}

  @doc "Write one entry down. The backends call this."
  @spec record(entry()) :: :ok
  def record(entry), do: Agent.update(__MODULE__, &[entry | &1])

  @doc "Everything that happened, in order."
  @spec entries() :: [entry()]
  def entries, do: __MODULE__ |> Agent.get(& &1) |> Enum.reverse()

  @doc """
  The levels that the backlight line was given, in order.

  1 is on and 0 is off. A board that wires the backlight to a supply gives none of
  these. See `MyHiFi.Peripheral.PiTft.Ili9341.backlight/2`.
  """
  @spec backlight() :: [0 | 1]
  def backlight, do: for({:backlight, level} <- entries(), do: level)

  @doc "Forget everything, so a test reads one draw and not the init sequence too."
  @spec forget() :: :ok
  def forget, do: Agent.update(__MODULE__, fn _entries -> [] end)

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
    entries()
    |> Enum.reduce({nil, []}, &fold/2)
    |> flush()
    |> Enum.reverse()
  end

  # The backlight says nothing about the bus, so it ends no command and opens none.
  defp fold({:backlight, _level}, state), do: state

  # The line goes low for a command, so a low level ends the command before it.
  defp fold({:gpio, 0}, state), do: {:awaiting_command, flush(state)}

  # The line goes high for data, and the bytes that follow belong to the command
  # that is already open.
  defp fold({:gpio, 1}, state), do: state

  defp fold({:spi, <<command>>}, {:awaiting_command, commands}), do: {{command, []}, commands}

  defp fold({:spi, payload}, {{command, parts}, commands}),
    do: {{command, [payload | parts]}, commands}

  defp fold({:spi, payload}, {:awaiting_command, _commands}) do
    raise "a command is one byte, and the screen got #{byte_size(payload)} with the line low"
  end

  defp fold({:spi, payload}, {nil, _commands}) do
    raise "the screen got #{byte_size(payload)} bytes before the line said command or data"
  end

  defp flush({{command, parts}, commands}),
    do: [{command, parts |> Enum.reverse() |> IO.iodata_to_binary()} | commands]

  defp flush({_nothing_open, commands}), do: commands

  defmodule Spi do
    @moduledoc "The SPI backend of `MyHiFi.Test.RecordingScreen`."

    @behaviour Circuits.SPI.Backend

    defstruct max_transfer_size: 4096

    @impl Circuits.SPI.Backend
    def bus_names(_options), do: ["spidev0.0", "spidev0.1"]

    @impl Circuits.SPI.Backend
    def open(_bus_name, options) do
      {:ok, %__MODULE__{max_transfer_size: Keyword.get(options, :max_transfer_size, 4096)}}
    end

    @impl Circuits.SPI.Backend
    def info, do: %{name: __MODULE__}

    defimpl Circuits.SPI.Bus do
      alias MyHiFi.Test.RecordingScreen

      def config(_bus), do: {:ok, %{mode: 0, bits_per_word: 8, speed_hz: 32_000_000, delay_us: 0}}

      def transfer(_bus, data) do
        data = IO.iodata_to_binary(data)
        RecordingScreen.record({:spi, data})
        {:ok, :binary.copy(<<0>>, byte_size(data))}
      end

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

      # The backlight is a GPIO as well, and it says nothing about the bus, so it goes
      # in the record under a name of its own and `commands/0` passes it by.
      @data_command 25
      @backlight 18

      def write(%{spec: @data_command}, value), do: RecordingScreen.record({:gpio, value})
      def write(%{spec: @backlight}, value), do: RecordingScreen.record({:backlight, value})
      def write(_handle, _value), do: :ok

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
