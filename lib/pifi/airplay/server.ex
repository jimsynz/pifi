defmodule PiFi.AirPlay.Server do
  @moduledoc """
  The listener a telephone connects to, and the switch that turns it on.

  **This opens a port, so a person turns it on**, in the way they turn on
  `PiFi.Plex.Companion`. A device nobody asked for AirPlay on advertises nothing and
  listens on nothing. The rule is `PiFi.Plex.Companion.enabled?/0`'s, and the reason is
  the same: a source a person never enabled shows them an empty list, and a listener a
  person never enabled is a hole in a device sitting on their home network.

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

  @enabled_key "airplay.enabled"
  @port 7000

  @doc """
  The port a receiver is expected on.

      iex> PiFi.AirPlay.Server.port()
      7000
  """
  @spec port() :: pos_integer()
  def port, do: @port

  @doc """
  The setting that says whether a person turned AirPlay on.

      iex> PiFi.AirPlay.Server.enabled_key()
      "airplay.enabled"
  """
  @spec enabled_key() :: String.t()
  def enabled_key, do: @enabled_key

  @doc """
  Whether a person turned AirPlay on. It is off until they do.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Settings.fetch(@enabled_key) do
      {:ok, %{value: "true"}} -> true
      _other -> false
    end
  end

  @doc """
  Turn AirPlay on or off, and make it so now rather than at the next boot.

  **It answers an error when the listener will not start**, rather than saying it is on
  and listening on nothing. A port another program holds, or an identity that cannot be
  read, is something a person needs telling about.
  """
  @spec enable(boolean()) :: :ok | {:error, term()}
  # **The setting follows the listener and does not lead it**, for the reason
  # `PiFi.Bluetooth.enable/1` gives: a port that another program holds would otherwise
  # leave a page saying off and a setting saying on.
  def enable(true) do
    case start_listener() do
      :ok ->
        Settings.put!(@enabled_key, "true")

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def enable(false) do
    Settings.put!(@enabled_key, "false")

    stop_listener()
  end

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
    if enabled?(), do: start_listener()

    :ok
  end

  @doc false
  @impl Supervisor
  def init(_options), do: Supervisor.init([], strategy: :one_for_one)

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
