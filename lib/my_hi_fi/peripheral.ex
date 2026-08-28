defmodule MyHiFi.Peripheral do
  @moduledoc """
  A piece of hardware that a person sees or touches.

  A screen, a knob, and a touch panel are all peripherals, and they share this one
  behaviour. A peripheral gets the events that it asks for, and it publishes what
  the person does. It never calls another part of the firmware directly.

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

  It does not own the navigation state. `MyHiFi.DeviceUi` owns that, because the
  knob needs a detent count and the count comes from the length of the list. A
  screen shows the part of a list that fits, so a screen does not know the length.

  `MyHiFi.Peripheral.Server` holds the process and the subscriptions, so a
  peripheral module holds no PubSub code and no process code.

  ## Which events arrive

  `c:subscriptions/0` names the topics, and this earns its place. A knob takes the
  hint topic only. It must not wake one time each second for a `Player.Progress`
  event that it cannot use.

  A peripheral ignores an event that it cannot use, and it gives `{:ok, state}` for
  it. A screen ignores the hints, and a knob ignores the view events. Nothing
  reports an error for this, because an ignored event is normal.

  A peripheral publishes with `MyHiFi.Event.publish/2`, from its own process. That
  needs no callback.
  """

  @typedoc "What one peripheral holds between events. The module chooses the shape."
  @type state :: term()

  @doc """
  Take hold of the hardware.

  `MyHiFi.Peripheral.Server` gives the options that started it, less the ones that
  it reads itself. An error here stops the server, and the supervisor decides what
  happens next.
  """
  @callback init(keyword()) :: {:ok, state()} | {:error, term()}

  @doc "The topics that this peripheral takes. See `MyHiFi.Event.topics/0`."
  @callback subscriptions() :: [MyHiFi.Event.topic()]

  @doc """
  Do something with one event.

  An event that this peripheral cannot use gives `{:ok, state}`.
  """
  @callback handle_event(MyHiFi.Event.t(), state()) :: {:ok, state()} | {:error, term()}

  @doc "Give the hardware back. A screen turns its backlight off here."
  @callback terminate(reason :: term(), state()) :: :ok

  @doc """
  The peripherals that this device holds, as children for a supervisor.

  `config/target.exs` names them, in the way that `:output` and `:sources` name
  theirs. A device with no screen and no knob names none, and a person who adds an
  SSD1306 screen adds a line there and changes nothing else.

      config :my_hi_fi, peripherals: [{MyHiFi.Peripheral.PiTft, rotation: :landscape}]

  The identifier of each child is the module of the peripheral, so one supervisor
  holds a screen and a knob together.
  """
  @spec child_specs() :: [Supervisor.child_spec()]
  def child_specs do
    :my_hi_fi
    |> Application.get_env(:peripherals, [])
    |> Enum.map(fn {module, opts} ->
      Supervisor.child_spec({MyHiFi.Peripheral.Server, [{:module, module} | opts]}, id: module)
    end)
  end
end
