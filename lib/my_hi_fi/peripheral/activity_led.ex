defmodule MyHiFi.Peripheral.ActivityLed do
  @moduledoc """
  The activity light of the board, as a warning that the cell is nearly flat.

  The Raspberry Pi holds one light that software can drive, and the case of the portable
  device lets a person see it. This peripheral flashes it while
  `MyHiFi.Event.Device.BatteryChanged` says that the charge is low, and it leaves the
  light dark at every other time.

  **The kernel does the flashing, and this process does not.** `/sys/class/leds/ACT`
  holds a `timer` trigger: a write of `timer` to `trigger` makes `delay_on` and
  `delay_off` appear, and the light then flashes on its own until something writes
  `none`. A process that wrote the brightness on a timer of its own would wake four
  times a second for as long as the cell stayed low, and it would stop flashing the
  moment that it died.

  ## Why this is a peripheral

  Every Raspberry Pi holds this light, so the part is not the question. **The case is.**
  A person sees it through the case of the portable device, and the light of the device
  on the stereo is inside a box where it says nothing to anybody. That is the same
  question that `MyHiFi.Peripheral.enabled?/1` answers for a screen, so it belongs here.

  ## It says one thing, and it says it in one way

  A light with one brightness and no colour can say very little, so it says the one thing
  that a person must act on: charge the cell. Adding a second meaning to it would leave a
  person reading a code of flashes, and the screen is where this device says anything
  that needs words.
  """

  @behaviour MyHiFi.Peripheral

  alias MyHiFi.Event.Device, as: Events

  require Logger

  # Sobelow reads `@sobelow_skip` from the source. This registration stops the compiler
  # warning that no Elixir code reads the attribute. See `MyHiFi.Output.Alsa`, which
  # does the same.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @path "/sys/class/leds/ACT"

  # 5 flashes each second. A slow flash reads as an ordinary activity light, and this
  # must read as a warning.
  @on_ms 100
  @off_ms 100

  @doc "The name that the settings page draws."
  @impl MyHiFi.Peripheral
  def title, do: "Activity light, for a low battery"

  @doc """
  Take hold of the light and leave it dark.

  ## Options

  - `:path` - the directory of the light in `/sys`. `#{@path}` by default.

  A board whose light is not there gives an error, and the settings page shows it.
  """
  @impl MyHiFi.Peripheral
  def init(opts) do
    path = Keyword.get(opts, :path, @path)

    with :ok <- steady(path) do
      {:ok, %{path: path, flashing?: false}}
    end
  end

  @doc "The light reads what the hardware does, and it uses no other topic."
  @impl MyHiFi.Peripheral
  def subscriptions, do: [:device]

  @doc false
  @impl MyHiFi.Peripheral
  def handle_event(%Events.BatteryChanged{low?: true}, state), do: {:ok, flash(state)}

  def handle_event(%Events.BatteryChanged{low?: false}, state), do: {:ok, dark(state)}

  # A change of the network, of the sound cards and of the free space all arrive here,
  # and none of them says anything about the cell.
  def handle_event(_event, state), do: {:ok, state}

  @doc "Leave the light dark and give it back."
  @impl MyHiFi.Peripheral
  def terminate(_reason, state) do
    steady(state.path)

    :ok
  end

  defp flash(%{flashing?: true} = state), do: state

  defp flash(state) do
    with :ok <- write(state.path, "trigger", "timer"),
         :ok <- write(state.path, "delay_on", to_string(@on_ms)),
         :ok <- write(state.path, "delay_off", to_string(@off_ms)) do
      %{state | flashing?: true}
    else
      {:error, reason} -> report(state, reason)
    end
  end

  defp dark(%{flashing?: false} = state), do: state

  defp dark(state) do
    case steady(state.path) do
      :ok -> %{state | flashing?: false}
      {:error, reason} -> report(state, reason)
    end
  end

  # `delay_on` and `delay_off` belong to the timer trigger, so they go when it goes. The
  # brightness therefore comes after, or the light keeps the level that it last held.
  defp steady(path) do
    with :ok <- write(path, "trigger", "none") do
      write(path, "brightness", "0")
    end
  end

  # A light that does not answer must never stop this process. A person who cannot see a
  # warning light still holds a device that plays music and a screen that says the same
  # thing in words.
  defp report(state, reason) do
    Logger.warning("The activity light did not answer: #{inspect(reason)}")

    state
  end

  # Sobelow reads a `Path.join/2` inside `File.write/2` as a traversal. **Neither part
  # comes from a request.** `path` is the constant above or a value that
  # `config/target.exs` names, and each `file` is one of the four literals in this
  # module. A person reaches nothing here.
  @sobelow_skip ["Traversal.FileModule"]
  defp write(path, file, value), do: File.write(Path.join(path, file), value)
end
