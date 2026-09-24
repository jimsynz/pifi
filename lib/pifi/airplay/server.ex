defmodule PiFi.AirPlay.Server do
  @moduledoc """
  The listener a telephone connects to.

  **This opens a port, so a person turns it on**, in the way they turn on
  `PiFi.Plex.Companion`. A device nobody asked for AirPlay on advertises nothing and
  listens on nothing: a listener a person never enabled is a hole in a device sitting on
  their home network.

  ## The switch belongs to the source

  It used to be here, under a key of its own, with a settings page of its own. It is now
  the ordinary switch every source has, because a person looking for where to turn
  AirPlay on should find it beside the other music services rather than having to know
  it was somewhere else. `PiFi.Source.AirPlay` holds that end and
  `PiFi.AirPlay.Monitor` hears the change and calls `enable/1` here.

  So this starts and stops the listener and writes no setting at all. A device that was
  upgraded still carries the old key, and `start_enabled/0` moves it across once.

  ## The listener comes up before the advertisement

  A telephone that read the mDNS record and dialled a port that was not open yet would
  show the device and then fail to connect, which looks like a broken receiver rather
  than one still starting. So the order is: listen, then advertise. Switching off goes
  the other way, and `MdnsLite` is told to forget the service before the socket closes.

  ## Port 7000, and nothing chooses otherwise

  Unlike the Plex player, which names its own port when it publishes its address, an
  AirPlay receiver is expected on 7000. A sender that found the mDNS record would honour
  another port, but the rest of the world assumes this one and there is nothing to gain
  by differing.
  """

  use Supervisor

  require Logger

  alias PiFi.AirPlay.Device
  alias PiFi.Settings

  # **What the switch used to be written under.** Nothing writes it now, and
  # `start_enabled/0` reads it once on a device that was upgraded so a person who had
  # AirPlay on does not find it off.
  @former_key "airplay.enabled"
  @port 7000

  @doc """
  The port a receiver is expected on.

      iex> PiFi.AirPlay.Server.port()
      7000
  """
  @spec port() :: pos_integer()
  def port, do: @port

  @doc """
  Whether a person turned AirPlay on. It is off until they do.

  The answer is the source's, because the switch is the source's.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: PiFi.Source.enabled?(PiFi.Source.AirPlay)

  @doc """
  Start or stop the listener now, rather than at the next boot.

  **It answers an error when the listener will not start**, rather than saying nothing
  and listening on nothing. A port another program holds, or an identity that cannot be
  read, is something a person needs telling about — and `PiFi.AirPlay.Monitor` puts the
  switch back when it hears one, so a page never says on over a port that is shut.
  """
  @spec enable(boolean()) :: :ok | {:error, term()}
  def enable(true), do: start_listener()
  def enable(false), do: stop_listener()

  @doc "Whether the listener is running now."
  @spec running?() :: boolean()
  def running? do
    Supervisor.which_children(__MODULE__)
    |> Enum.any?(fn {id, pid, _type, _modules} -> id == :listener and is_pid(pid) end)
  end

  @doc """
  Start the listener when a person asked for it.

  `PiFi.Application` calls this after the tree, the way it calls
  `PiFi.Plex.Companion.start_enabled/0`. **A port another program holds must not stop
  the boot**, and a child of the tree that cannot start would do that.
  """
  @spec start_enabled() :: :ok
  def start_enabled do
    carry_over()

    if enabled?(), do: start_listener()

    :ok
  end

  # A device made before the switch moved has its answer under the old key, and the
  # sources list would show AirPlay off for someone who had turned it on. Read once,
  # write across, and leave the old one where it is: nothing reads it again, and a
  # person who writes a card gets a device with neither.
  defp carry_over do
    with {:error, _missing} <- Settings.fetch(PiFi.Source.enabled_key(PiFi.Source.AirPlay)),
         {:ok, %{value: value}} when value in ["true", "false"] <- Settings.fetch(@former_key) do
      Settings.put!(PiFi.Source.enabled_key(PiFi.Source.AirPlay), value)
    end

    :ok
  end

  @doc false
  @impl Supervisor
  # The monitor is always here, because it is what hears the switch being turned on.
  # The listener is added and removed beside it.
  def init(_options),
    do: Supervisor.init([{PiFi.AirPlay.Monitor, []}], strategy: :one_for_one)

  @doc false
  def start_link(options), do: Supervisor.start_link(__MODULE__, options, name: __MODULE__)

  # **A receiver that cannot start must not take down whatever asked it to.** At a boot
  # that is the whole firmware, and on the settings page it is the page a person is
  # looking at. Either way it is logged and answered, and never raised.
  defp attempt(what) do
    what.()
  rescue
    error -> {:error, error}
  end

  defp start_listener do
    case attempt(fn -> Supervisor.start_child(__MODULE__, listener()) end) do
      {:ok, _pid} -> advertise()
      {:error, :already_present} -> restart()
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> refused(reason)
    end
  end

  defp restart do
    case attempt(fn -> Supervisor.restart_child(__MODULE__, :listener) end) do
      {:ok, _pid} -> advertise()
      {:error, :running} -> :ok
      {:error, reason} -> refused(reason)
    end
  end

  defp refused(reason) do
    Logger.warning("AirPlay did not start: #{inspect(reason)}")

    {:error, reason}
  end

  defp stop_listener do
    withdraw()

    Supervisor.terminate_child(__MODULE__, :listener)
    Supervisor.delete_child(__MODULE__, :listener)

    :ok
  end

  # `mdns_lite` arrives through `nerves_pack`, which is a target dependency, so a
  # reference to it must not reach a host build. `PiFi.Device.Identity` does the same.
  if Mix.target() == :host do
    defp advertise, do: :ok
    defp withdraw, do: :ok
  else
    alias PiFi.AirPlay.Advertisement

    @service_id :airplay

    # A telephone that read the record and found nothing listening looks at a broken
    # receiver, so this happens after the socket is open and never before it.
    defp advertise do
      data_dir()
      |> Device.facts()
      |> Advertisement.service(@port)
      |> MdnsLite.add_mdns_service()

      Logger.info("AirPlay is listening on #{@port}.")

      :ok
    end

    defp withdraw, do: MdnsLite.remove_mdns_service(@service_id)
  end

  # `/root` is the writable partition of a target and somebody's home directory on a
  # host, so a test writes somewhere it may. `:switch_off_marker` is set the same way.
  defp data_dir, do: Application.get_env(:pifi, :airplay_data_dir, "/root")

  defp listener do
    %{
      id: :listener,
      start:
        {ThousandIsland, :start_link,
         [
           [
             port: @port,
             handler_module: PiFi.AirPlay.Connection,
             handler_options: %{device: Device.facts(data_dir()), data_dir: data_dir()}
           ]
         ]}
    }
  end
end
