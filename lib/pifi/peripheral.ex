defmodule PiFi.Peripheral do
  @moduledoc """
  A piece of hardware that a board may hold, and may not.

  A screen, a knob, a touch panel and a battery gauge are all peripherals, and they
  share this one behaviour. A peripheral gets the events that it asks for, and it
  publishes what it reads or what the person does. It never calls another part of the
  firmware directly.

  **The rule is the bus, and not the finger.** An earlier version of this sentence said
  "a piece of hardware that a person sees or touches", which fits a screen and a knob and
  not `PiFi.Peripheral.Battery`. What every one of them shares is the reason for
  `enabled?/1`: the same image runs on a board that has the part and on a board that
  does not, and a bus with nothing on it gives an error at each start.

  One behaviour, and not one for a screen and one for a control, has a hardware
  reason. On the PiTFT the ILI9341 screen and the STMPE610 touch controller share
  SPI0 and use separate chip select lines. One process therefore owns the bus, and
  no arbitration is necessary. Two processes on one bus would need it.

  **A peripheral renders itself.** No part of the firmware sends it pixels or
  frames. A 128 by 64 monochrome screen and a 320 by 240 colour screen need
  different layouts, and each one decides its own. A peripheral therefore owns:

  - The hardware link, such as SPI or I2C.
  - The size, the colour model, and the refresh rate of a screen.
  - The layout, the fonts, and the scroll window.
  - The rate of the events that it publishes.

  It does not own the navigation state. `PiFi.DeviceUi` owns that, because the
  knob needs a detent count and the count comes from the length of the list. A
  screen shows the part of a list that fits, so a screen does not know the length.

  **A layout is its own, and the parts of it are not.** A battery, a bar and the
  black band under a mark read the same way on every screen of this device, so
  `PiFi.Screen` keeps them, and a screen composes them where it wants. A screen that
  drew its own battery would give a person two devices to read.

  `PiFi.Peripheral.Server` owns the process and the subscriptions, so a
  peripheral module needs no PubSub code and no process code.

  ## Which events arrive

  `c:subscriptions/0` names the topics, and this earns its place. A knob takes the
  hint topic only. It must not wake one time each second for a `Player.Progress`
  event that it cannot use.

  A peripheral ignores an event that it cannot use, and it returns `{:ok, state}` for
  it. A screen ignores the hints, and a knob ignores the view events. Nothing
  reports an error for this, because an ignored event is normal.

  A peripheral publishes with `PiFi.Event.publish/2`, from its own process. That
  needs no callback.

  ## Which peripherals run

  Two answers make one. `all/0` names the peripherals that this firmware knows, and
  it comes from the configuration. `enabled?/1` says whether the part is wired to
  this board, and it comes from the settings, because a person answers it.

  **A firmware cannot know what a board has.** The same image runs on a board with
  a screen and on a board with none, and a bus with nothing on it gives an error at
  each start. A peripheral is therefore out of use until a person says otherwise, and
  the settings page is where they say it.

  `PiFi.Peripheral.Supervisor` owns the processes, and `start/1` and `stop/1` move
  one in and out of it. A change therefore reaches the hardware at once, and it also
  survives a restart.
  """

  require Logger

  alias PiFi.Settings

  @typedoc "What one peripheral keeps between events. The module chooses the shape."
  @type state :: term()

  @doc """
  The name of this peripheral, for a person to read.

  The settings page draws this, and it needs no list of the peripherals.
  """
  @callback title() :: String.t()

  @doc """
  Take hold of the hardware.

  `PiFi.Peripheral.Server` gives the options that started it, less the ones that
  it reads itself. An error here stops the server, and the supervisor decides what
  happens next.
  """
  @callback init(keyword()) :: {:ok, state()} | {:error, term()}

  @doc "The topics that this peripheral takes. See `PiFi.Event.topics/0`."
  @callback subscriptions() :: [PiFi.Event.topic()]

  @doc """
  Do something with one event.

  An event that this peripheral cannot use gives `{:ok, state}`.
  """
  @callback handle_event(PiFi.Event.t(), state()) :: {:ok, state()} | {:error, term()}

  @doc "Give the hardware back. A screen turns its backlight off here."
  @callback terminate(reason :: term(), state()) :: :ok

  @doc """
  Do something with a message that is not an event.

  Hardware speaks to the process that owns it, and a button of a GPIO line sends
  `{:circuits_gpio, pin, timestamp, value}` for each change of level. A peripheral
  that reads such a message names this callback, and it usually turns the message
  into an event of the `:input` topic. See `PiFi.Peripheral.PiTft`.

  A peripheral with nothing that speaks by itself names none, and
  `PiFi.Peripheral.Server` then writes the message in the log and continues.
  """
  @callback handle_info(message :: term(), state()) :: {:ok, state()} | {:error, term()}

  @doc """
  Whether this peripheral draws a screen.

  **A device holds a screen or it does not, and the settings of a screen belong to
  the first one.** A person with a knob and a battery gauge and no panel has no use
  for a page that sets how long the screen waits before it goes dark.

  A peripheral that draws nothing names this callback never, and `screen?/1` reads
  `false` for it.
  """
  @callback screen?() :: boolean()

  @optional_callbacks handle_info: 2, screen?: 0

  @doc """
  The peripherals that this device can hold.

  `config/target.exs` names them, in the way that `:output` and `:sources` name
  theirs. Each entry names the module and the options that reach `c:init/1`.

      config :pifi, peripherals: [{PiFi.Peripheral.PiTft, rotation: :landscape}]

  A name here says that the firmware knows the part. It does not say that the part
  is wired to this board. `enabled?/1` says that, and a person answers it.
  """
  @spec all() :: [{module(), keyword()}]
  def all, do: Application.get_env(:pifi, :peripherals, [])

  @doc """
  Put a peripheral in use, or take it out of use.

  This writes the setting and it starts or stops the process, so a person sees a
  screen light up and go dark without a restart.

  A start that fails still leaves the setting as the person asked for it. A person
  who turns the screen on and then wires it expects it to come up on the next boot.
  """
  @spec enable(module(), boolean()) :: :ok | {:error, term()}
  def enable(module, true) do
    Settings.put!(enabled_key(module), "true")

    start(module)
  end

  def enable(module, false) do
    Settings.put!(enabled_key(module), "false")

    stop(module)
  end

  @doc """
  The settings key that says whether a peripheral is in use.

      iex> PiFi.Peripheral.enabled_key(PiFi.Peripheral.PiTft)
      "peripheral.pi-tft.enabled"
  """
  @spec enabled_key(module()) :: String.t()
  def enabled_key(module), do: "peripheral." <> slug(module) <> ".enabled"

  @doc """
  Whether a person put this peripheral in use.

  A peripheral that no person changed is **out of use**, and this is the opposite of
  `PiFi.Source.enabled?/1`. The hardware is the reason. A source that no person
  asked for reads a service and shows a list, and it costs nothing. A screen that no
  person wired cannot answer, and a firmware that opens a bus with nothing on it
  gives a fault at each start. A person therefore says that the part is there.
  """
  @spec enabled?(module()) :: boolean()
  def enabled?(module) do
    case Settings.fetch(enabled_key(module)) do
      {:ok, %{value: "true"}} -> true
      _other -> false
    end
  end

  @doc """
  Whether this peripheral draws a screen.

  A peripheral that names no `c:screen?/0` draws none. See that callback.

      iex> PiFi.Peripheral.screen?(PiFi.Peripheral.PiTft)
      true

      iex> PiFi.Peripheral.screen?(PiFi.Peripheral.Battery)
      false
  """
  @spec screen?(module()) :: boolean()
  def screen?(module) do
    # **`function_exported?/3` answers for a module that is loaded, and no other.** A
    # release of this firmware loads every module at the boot, and a host build loads
    # one when something calls it, so a check that stood alone here read `false` for a
    # peripheral that nothing had touched yet.
    Code.ensure_loaded?(module) and function_exported?(module, :screen?, 0) and
      module.screen?()
  end

  @doc """
  Whether this device draws a screen now.

  **It asks which peripherals a person put in use, and not which ones this firmware
  knows.** The same image runs on a board with a panel and on a board with none, so
  the answer is a setting and never a compile-time fact. A page about a screen reads
  this, and it draws nothing for a device that has none.
  """
  @spec any_screen?() :: boolean()
  def any_screen? do
    Enum.any?(all(), fn {module, _options} -> screen?(module) and enabled?(module) end)
  end

  @doc """
  Read a peripheral back from its name.

  The name comes from a request, so this compares it with the name of each
  peripheral of `all/0`. It turns no text into an atom, and an unknown name gives an
  error. See `PiFi.Source.from_slug/1`, which does the same for a source.
  """
  @spec from_slug(String.t()) :: {:ok, module()} | {:error, :not_a_peripheral}
  def from_slug(name) do
    case Enum.find(all(), fn {module, _options} -> slug(module) == name end) do
      nil -> {:error, :not_a_peripheral}
      {module, _options} -> {:ok, module}
    end
  end

  @doc """
  Whether this peripheral has its hardware now.

  A peripheral that a person put in use and that did not start gives `false`, so a
  settings page can say the difference.
  """
  @spec running?(module()) :: boolean()
  def running?(module) do
    __MODULE__.Supervisor
    |> Supervisor.which_children()
    |> Enum.any?(fn {id, pid, _type, _modules} -> id == module and is_pid(pid) end)
  end

  @doc """
  The name of a peripheral in an address and in a settings key.

      iex> PiFi.Peripheral.slug(PiFi.Peripheral.PiTft)
      "pi-tft"
  """
  @spec slug(module()) :: String.t()
  def slug(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.replace("_", "-")
  end

  @doc """
  Start one peripheral now.

  It returns `{:error, reason}` for hardware that does not answer, and a settings page
  shows that sentence to the person who asked. See `PiFi.Peripheral.Server`.
  """
  @spec start(module()) :: :ok | {:error, term()}
  def start(module) do
    case Supervisor.start_child(__MODULE__.Supervisor, spec(module)) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, error} -> {:error, reason(error)}
    end
  end

  @doc """
  Start each peripheral that a person put in use.

  `PiFi.Application` calls this after the supervision tree starts, and it is not
  the child list of `PiFi.Peripheral.Supervisor`. A child that fails to start stops
  the whole start of a supervisor, and a screen that no person wired must never keep
  the music from playing.
  """
  @spec start_enabled() :: :ok
  def start_enabled do
    Enum.each(all(), fn {module, _options} ->
      if enabled?(module), do: report(module, start(module))
    end)
  end

  @doc """
  Stop one peripheral now.

  `c:terminate/2` runs, so a screen turns its backlight off before the process goes.
  """
  @spec stop(module()) :: :ok
  def stop(module) do
    Supervisor.terminate_child(__MODULE__.Supervisor, module)
    Supervisor.delete_child(__MODULE__.Supervisor, module)

    :ok
  end

  # The options of `all/0` reach `c:init/1`, and the identifier of the child is the
  # module, so one supervisor runs a screen and a knob together.
  defp spec(module) do
    Supervisor.child_spec({__MODULE__.Server, [{:module, module} | options(module)]}, id: module)
  end

  # A supervisor of OTP puts its own record of the child beside the reason of a start
  # that failed, and `:child` is the tag of that record. A person reads the reason, and
  # the record means nothing to them.
  defp reason({reason, child}) when is_tuple(child) and elem(child, 0) == :child, do: reason

  defp reason(error), do: error

  defp options(module) do
    case List.keyfind(all(), module, 0) do
      {^module, options} -> options
      nil -> []
    end
  end

  defp report(_module, :ok), do: :ok

  defp report(module, {:error, reason}) do
    Logger.error("#{module.title()} did not start: #{inspect(reason)}")
  end
end
