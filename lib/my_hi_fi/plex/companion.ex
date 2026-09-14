defmodule MyHiFi.Plex.Companion do
  @moduledoc """
  Lets another Plex application control this device.

  A person holds their telephone and presses play, and the music comes out of the
  stereo. Plex calls that a Companion player: the controller holds the list and the
  artwork, and the player holds the sound.

  `MyHiFi.Plex.Companion.Router` answers the requests of a controller, and this module
  is the door that turns the player on and off.

  ## A person turns this on, and a device that no person asked leaves it off

  **This is the first part of the firmware that listens for anything.** Every other
  part connects out: the web interface answers on the local network, and
  `nerves_hub_link` opens no port at all. A player must listen, because a controller
  sends the commands to it.

  `enabled?/0` is therefore the rule, and it follows `MyHiFi.Peripheral.enabled?/1`:
  the setting decides, and a device that no person changed holds the port closed. The
  supervisor starts with no child for that reason.

  ## What a controller needs, and what is still missing

  A controller finds a player in two ways, and this module serves neither of them yet.

  - **plex.tv lists the players of an account.** Plexamp on iOS reads that list and
    runs no discovery of its own, so a device that is absent from it cannot be found by
    the telephone of a person. That needs `X-Plex-Provides: client,player,pubsub-player`
    and a `PUT` of the address of this player to `/devices/{id}`.
  - **GDM finds a player on the same network.** A controller broadcasts
    `M-SEARCH * HTTP/1.0` to UDP port 32412, and a player answers from that port.

  **Both are absent on purpose.** The shape of every answer below comes from reading
  what other implementations do, and no part of it is a published specification. A
  person must therefore point a controller at this device by hand and say what happens,
  and the two things that I expect to be wrong are in `MyHiFi.Plex.Companion.Router`.
  """

  use Supervisor

  require Logger

  alias MyHiFi.Settings

  @enabled_key "plex.companion.enabled"

  # **The port is a guess, and the published address is what settles it.** A player
  # names its own port when it tells plex.tv where it is, so any number serves. Of the
  # two implementations that I read, `python-plexapi` assumes 32433 for a player that
  # named none, and the plugin of another project publishes 32500. This takes the
  # second, because that one is a player of music and the other is a library.
  @port 32_500

  @doc "The port that this player listens on."
  @spec port() :: pos_integer()
  def port, do: @port

  @doc """
  The settings key that says whether a person turned the player on.

      iex> MyHiFi.Plex.Companion.enabled_key()
      "plex.companion.enabled"
  """
  @spec enabled_key() :: String.t()
  def enabled_key, do: @enabled_key

  @doc """
  Whether a person turned the player on.

  **A device that no person changed leaves it off.** This is the opposite of
  `MyHiFi.Source.enabled?/1`, and the port is the reason: a source that a person never
  asked for shows them an empty list, and a listener that a person never asked for is a
  door into the device.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Settings.fetch(@enabled_key) do
      {:ok, %{value: "true"}} -> true
      _other -> false
    end
  end

  @doc """
  Turn the player on, or off.

  It starts the listener, or it stops it, so a person hears the change without a
  restart.
  """
  @spec enable(boolean()) :: :ok
  def enable(enabled?) do
    Settings.put!(@enabled_key, to_string(enabled?))

    if enabled?, do: start_listener(), else: stop_listener()

    :ok
  end

  @doc "Whether the listener is running now."
  @spec running?() :: boolean()
  def running? do
    Supervisor.which_children(__MODULE__)
    |> Enum.any?(fn {id, pid, _type, _modules} -> id == :listener and is_pid(pid) end)
  end

  @doc """
  Start the listener when a person asked for it.

  `MyHiFi.Application` calls this after the tree, in the way that it calls
  `MyHiFi.Peripheral.start_enabled/0`. **A port that another program holds must not
  stop the boot**, and a child of the tree that cannot start would do that.
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

  defp start_listener do
    case Supervisor.start_child(__MODULE__, listener()) do
      {:ok, _pid} ->
        Logger.info("The Plex player listens on port #{@port}.")

      {:error, :already_present} ->
        Supervisor.restart_child(__MODULE__, :listener)

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning("The Plex player did not start: #{inspect(reason)}")
    end

    :ok
  end

  defp stop_listener do
    Supervisor.terminate_child(__MODULE__, :listener)
    Supervisor.delete_child(__MODULE__, :listener)

    :ok
  end

  defp listener do
    %{
      id: :listener,
      start:
        {Bandit, :start_link, [[plug: MyHiFi.Plex.Companion.Router, port: @port, scheme: :http]]}
    }
  end
end
