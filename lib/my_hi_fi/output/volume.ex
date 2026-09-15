defmodule MyHiFi.Output.Volume do
  @moduledoc """
  The level of the output, and who owns the number.

  **A person turns this on, and it is off until they do.** A stereo has always had its
  level on the amplifier, and a DAC that attenuates in the digital domain throws bits
  away to do it: 50 percent of the range of a 16 bit card is 15 bits. A person who
  drives an amplifier therefore wants the card at 0 dB and nothing in front of it, and
  that is the state that this firmware starts in. A person who drives headphones or
  powered speakers has nowhere else to set it, and they turn this on.

  **The setting keeps the number, and the card is only told it.** A read of a card
  cannot give the number back: a measurement on 2026-09-09 set 60 percent on the
  HiFimeDIY USB DAC and read 59, because that card has 111 steps and no step lands on
  every percentage. A control that read the card would move under the hand of the
  person using it. The settings are therefore the one source of truth, and
  `MyHiFi.Output.put_volume/2` is a write and never a read.

  ## Why it is a process of its own

  The hardware forgets the level at each boot, and a card that a person plugs in later
  has never been told it. This process keeps the number, writes it at the start, and
  writes it again whenever `MyHiFi.Event.Device.OutputChanged` says that the card in
  use changed. `MyHiFi.Player` could hold it, and it answers a control in more than a
  dozen clauses, so a write in each one is a write that the next clause forgets. That is
  the reason that `MyHiFi.AutoStandby` is a process as well.

  ## Turning it off returns the card to 0 dB

  A person who attenuates to 30 percent and then turns the control off would otherwise
  leave a card that plays quietly with nothing in the firmware that can raise it. Off
  therefore means 0 dB and not "the last number", and a person who turns it on again
  gets the number that they chose before.
  """

  use GenServer

  require Logger

  alias MyHiFi.Event
  alias MyHiFi.Event.Device, as: DeviceEvents
  alias MyHiFi.Event.Player, as: Events
  alias MyHiFi.Output
  alias MyHiFi.Settings

  @percent_key "output.volume"
  @enabled_key "output.volume.enabled"

  # A control that a person turns on must change nothing that they can hear, so it
  # starts where the card already is.
  @default_percent 100

  @doc "Start the owner of the level."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @doc "The settings key of the level."
  @spec percent_key() :: String.t()
  def percent_key, do: @percent_key

  @doc "The settings key that says whether this firmware sets the level."
  @spec enabled_key() :: String.t()
  def enabled_key, do: @enabled_key

  @doc """
  What the level is, whether the control is on, and whether the card has one.

  A caller reads all three together, because each one alone says nothing that a person
  can act on: a level of 30 means nothing on a card that this firmware cannot set.
  """
  @spec state(GenServer.server()) :: %{
          percent: Output.percent(),
          enabled?: boolean(),
          supported?: boolean()
        }
  def state(server \\ __MODULE__) do
    GenServer.call(server, :state)
  catch
    :exit, reason ->
      log(reason)

      fixed()
  end

  # **An owner that is not there and one that will not answer are different faults.**
  # A test starts no listener of the node, so `:noproc` is the normal state of a suite
  # and a warning for each page of it would say nothing. A timeout is a process that is
  # stuck, and that is worth a line.
  defp log({:noproc, _call}), do: Logger.debug("No process keeps the level of the output.")

  defp log(reason), do: Logger.warning("The volume did not say what it is: #{inspect(reason)}")

  @doc """
  The state of a device whose level nothing sets.

  **A reader of the level never waits for this process and never dies with it.** Every
  page of the web interface reads the level, and a process that was absent for a moment
  would otherwise take each of those pages with it. This is the rule of
  `MyHiFi.Playback.Player.state/0`, and the reason is the same.

  It says that the card plays at its loudest and that nothing sets it, which is the
  state of a device that no person has set. A page that draws this needs no control that
  can do harm, and the next event corrects it.
  """
  @spec fixed() :: %{percent: Output.percent(), enabled?: boolean(), supported?: boolean()}
  def fixed, do: %{percent: @default_percent, enabled?: false, supported?: false}

  @doc """
  Set the level.

  It writes the setting and the card, and it publishes what it did. A card with
  no level takes the setting and nothing else, so a person who plugs in a DAC that
  has one hears the number that they chose.
  """
  @spec set_percent(GenServer.server(), Output.percent()) ::
          :ok | {:error, :out_of_range | :not_enabled}
  def set_percent(server \\ __MODULE__, percent)

  def set_percent(server, percent) when is_integer(percent) and percent in 0..100,
    do: GenServer.call(server, {:set_percent, percent})

  def set_percent(_server, _percent), do: {:error, :out_of_range}

  @doc """
  Turn the control on, or off.

  Off returns the card to 0 dB, so a person never leaves a card that plays quietly with
  nothing that can raise it. See the module documentation.
  """
  @spec enable(GenServer.server(), boolean()) :: :ok
  def enable(server \\ __MODULE__, enabled?) when is_boolean(enabled?),
    do: GenServer.call(server, {:enable, enabled?})

  @doc false
  @impl GenServer
  def init(_options) do
    # The subscription comes before the first write, or a card that arrives between the
    # two is a card that nothing tells.
    :ok = Event.subscribe(:device)

    state = %{
      percent: stored_percent(),
      enabled?: stored_enabled?(),
      device: nil,
      supported?: false
    }

    {:ok, state, {:continue, :apply}}
  end

  # The hardware forgets the level at each boot, so the number goes to the card here.
  # It runs after `init/1` gives the process to the supervisor, because a read of the
  # card in use asks the player and the player answers a call.
  @doc false
  @impl GenServer
  def handle_continue(:apply, state) do
    state = card(state, device())

    write(state)

    {:noreply, state}
  end

  # **This answers from what it keeps, and it asks the player nothing.** A read of the
  # card in use is a call to `MyHiFi.Player`, and that process is busy for as long as a
  # change of track takes: it stops one pipeline and starts the next inside the call
  # that it is answering. Every page of the web interface reads the level, so each of
  # them waited behind that work and then logged
  # `The volume did not say what it is: {:timeout, ...}` after five seconds.
  #
  # `MyHiFi.Event.Device.OutputChanged` names the card in use, and it arrives for a card
  # that comes or goes and for a card that a person chooses, so what this keeps stays
  # right without a question.
  @doc false
  @impl GenServer
  def handle_call(:state, _from, state), do: {:reply, report(state), state}

  @impl GenServer
  def handle_call({:set_percent, percent}, _from, %{enabled?: false} = state) do
    Settings.put(@percent_key, to_string(percent))

    {:reply, {:error, :not_enabled}, %{state | percent: percent}}
  end

  @impl GenServer
  def handle_call({:set_percent, percent}, _from, state) do
    state = %{state | percent: percent}

    Settings.put(@percent_key, to_string(percent))
    write(state)
    publish(state)

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:enable, enabled?}, _from, state) do
    state = %{state | enabled?: enabled?}

    Settings.put(@enabled_key, to_string(enabled?))
    write(state)
    publish(state)

    {:reply, :ok, state}
  end

  # **A card that a person plugs in has never been told the level.** The event names
  # the card in use, so this keeps that card and asks the player nothing.
  @doc false
  @impl GenServer
  def handle_info(%DeviceEvents.OutputChanged{in_use: in_use}, state) do
    state = card(state, in_use)

    write(state)

    {:noreply, state}
  end

  def handle_info(%_{}, state), do: {:noreply, state}

  # Off means 0 dB, and not the last number that a person chose. See the module
  # documentation.
  defp write(%{enabled?: true} = state), do: put(state, state.percent)
  defp write(%{enabled?: false} = state), do: put(state, @default_percent)

  defp put(%{device: nil}, _percent), do: :ok

  defp put(%{device: device_id}, percent) do
    case Output.put_volume(device_id, percent) do
      :ok -> :ok
      {:error, reason} -> Logger.debug("The card took no level: #{inspect(reason)}")
    end
  end

  defp publish(state), do: Event.publish(:player, struct(Events.VolumeChanged, report(state)))

  defp report(state) do
    %{
      percent: state.percent,
      enabled?: state.enabled?,
      supported?: state.supported?
    }
  end

  # The card that makes the sound, and whether a person can move its level. **The read
  # of the card runs here and never in a call**, because `amixer` is a program of its
  # own and a page that waited for one waited for the card to answer. A device with no
  # card has no level, and a card that this firmware cannot set has none that a person
  # can move.
  defp card(state, nil), do: %{state | device: nil, supported?: false}

  defp card(state, device_id),
    do: %{state | device: device_id, supported?: Output.volume?(device_id)}

  # The card in use, and not the one that a person chose. A chosen card that is absent
  # plays through another one, and the level belongs to the card that makes the sound.
  #
  # **This runs at the start of the process and nowhere else.** The event carries the
  # card after that. See `handle_call(:state, ...)`.
  defp device do
    case MyHiFi.Player.output() do
      %{in_use: in_use} -> in_use
      _other -> nil
    end
  catch
    :exit, _reason -> nil
  end

  # A row that carries something that is not a number is a row that no part of this
  # firmware writes, and the loudest level is a better answer than a process that will
  # not start.
  defp stored_percent do
    with {:ok, %{value: value}} <- Settings.fetch(@percent_key),
         {percent, ""} when percent in 0..100 <- Integer.parse(value) do
      percent
    else
      _other -> @default_percent
    end
  end

  defp stored_enabled? do
    case Settings.fetch(@enabled_key) do
      {:ok, %{value: "true"}} -> true
      _other -> false
    end
  end
end
