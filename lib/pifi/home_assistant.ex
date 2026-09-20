defmodule PiFi.HomeAssistant do
  @moduledoc """
  Lets Home Assistant see this device as a media player.

  A person puts the stereo in a scene, or on a dashboard beside the lamps, and the
  automations of their house can pause the music when the doorbell goes.

  ## It speaks the ESPHome protocol, and not MQTT

  **Home Assistant has no MQTT media player.** Its MQTT integration serves lights,
  switches, sensors and two dozen other platforms, and a player is not one of them. Its
  ESPHome integration does serve one, so this device answers the native API of ESPHome
  and Home Assistant discovers it as a node.

  `homex` is the bridge, and the media player entity of it is ours: see
  `PiFi.HomeAssistant.Player`. `mix.exs` points at a branch of a fork for that reason.

  ## A person turns this on, and a device that no person asked leaves it off

  **It listens on TCP port 6053.** That is the second listener of this firmware, and
  the rule is the one that `PiFi.Plex.Companion` follows: the setting decides, a device
  that no person changed holds the port closed, and the supervisor starts with no
  child.

  ## Home Assistant finds it over mDNS

  `mdns_lite` is already in this firmware, and it is what names the device on the
  network. `homex` therefore gets `mdns: :mdns_lite`, which is the responder that a
  Nerves device wants: the `:system` one shells out to the responder of the operating
  system, which a Nerves target does not have.

  A host runs the tests of this module and advertises nothing, because a laptop that
  answered as an ESPHome node would offer a player that goes when the test ends.
  """

  use Supervisor

  require Logger

  alias Homex.Adapter.ESPHome
  alias PiFi.Device.Identity
  alias PiFi.Device.Upgrade
  alias PiFi.HomeAssistant.Player
  alias PiFi.Settings

  @enabled_key "home_assistant.enabled"

  # The port of the native API of ESPHome. Home Assistant assumes it for a node that
  # names none, so this is not ours to choose.
  @port 6053

  @doc "The port that this listens on."
  @spec port() :: pos_integer()
  def port, do: @port

  @doc """
  The settings key that says whether a person turned this on.

      iex> PiFi.HomeAssistant.enabled_key()
      "home_assistant.enabled"
  """
  @spec enabled_key() :: String.t()
  def enabled_key, do: @enabled_key

  @doc """
  Whether a person turned this on.

  **A device that no person changed leaves it off**, because this opens a port. See
  `PiFi.Plex.Companion.enabled?/0`, which is the same rule for the same reason.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Settings.fetch(@enabled_key) do
      {:ok, %{value: "true"}} -> true
      _other -> false
    end
  end

  @doc """
  Turn it on, or off.

  It starts the bridge, or it stops it, so a person hears the change without a restart.
  """
  @spec enable(boolean()) :: :ok
  def enable(enabled?) do
    Settings.put!(@enabled_key, to_string(enabled?))

    if enabled?, do: start_bridge(), else: stop_bridge()

    :ok
  end

  @doc "Whether the bridge is running now."
  @spec running?() :: boolean()
  def running? do
    Supervisor.which_children(__MODULE__)
    |> Enum.any?(fn {id, pid, _type, _modules} -> id == :homex and is_pid(pid) end)
  end

  @doc """
  Start the bridge when a person asked for it.

  `PiFi.Application` calls this after the tree, in the way that it calls
  `PiFi.Plex.Companion.start_enabled/0`. **A port that another program holds must not
  stop the boot**, and a child of the tree that cannot start would do that.
  """
  @spec start_enabled() :: :ok
  def start_enabled do
    if enabled?(), do: start_bridge()

    :ok
  end

  @doc false
  @impl Supervisor
  def init(_options), do: Supervisor.init([], strategy: :one_for_one)

  @doc false
  def start_link(options), do: Supervisor.start_link(__MODULE__, options, name: __MODULE__)

  defp start_bridge do
    case Supervisor.start_child(__MODULE__, bridge()) do
      {:ok, _pid} ->
        Logger.info("Home Assistant can reach this device on port #{@port}.")

      {:error, :already_present} ->
        Supervisor.restart_child(__MODULE__, :homex)

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning("The Home Assistant bridge did not start: #{inspect(reason)}")
    end

    :ok
  end

  defp stop_bridge do
    Supervisor.terminate_child(__MODULE__, :homex)
    Supervisor.delete_child(__MODULE__, :homex)

    :ok
  end

  # **The name of the device is the name of the node**, so a household with two of
  # these reads two names in Home Assistant and not two copies of one. `id` is what
  # Home Assistant keeps the entity under, and it is the slug of that name, so a person
  # who renames the device gets a new node rather than a stale one under the old name.
  # See `PiFi.Device.Identity`.
  defp bridge do
    %{
      id: :homex,
      start:
        {Homex, :start_link,
         [
           [
             id: Identity.slug(),
             devices: [
               default: [
                 name: Identity.name(),
                 manufacturer: "PiFi",
                 model: Identity.default_name(),
                 sw_version: Upgrade.running_version()
               ]
             ],
             adapters: [{ESPHome, [port: @port] ++ mdns()}],
             entities: [Player]
           ]
         ]}
    }
  end

  if Mix.target() == :host do
    defp mdns, do: []
  else
    defp mdns, do: [mdns: :mdns_lite]
  end
end
