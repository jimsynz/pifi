defmodule PiFi.Plex.Companion do
  @moduledoc """
  Lets another Plex application control this device.

  A person holds their telephone and presses play, and the music comes out of the
  stereo. Plex calls that a Companion player: the controller holds the list and the
  artwork, and the player holds the sound.

  `PiFi.Plex.Companion.Router` answers the requests of a controller, and this module
  is the door that turns the player on and off.

  ## A person turns this on, and a device that no person asked leaves it off

  **This is the first part of the firmware that listens for anything.** Every other
  part connects out: the web interface answers on the local network, and the check for a
  new firmware reaches the forge and opens nothing. A player must listen, because a
  controller sends the commands to it.

  `enabled?/0` is therefore the rule, and it follows `PiFi.Peripheral.enabled?/1`:
  the setting decides, and a device that no person changed holds the port closed. The
  supervisor starts with no child for that reason.

  ## How a controller finds this player, and the two ways are both served

  - **plex.tv lists the players of an account.** Plexamp on iOS reads that list and
    runs no discovery of its own, so a device that is absent from it cannot be found by
    the telephone of a person. `PiFi.Plex.Companion.Announcement` publishes the address
    of this player to the account and keeps it current.
  - **GDM finds a player on the same network.** A controller broadcasts
    `M-SEARCH * HTTP/1.0` to UDP port 32412, and `PiFi.Plex.Companion.Gdm` answers it.
    A controller on a desktop uses this, and it needs no account at all.

  **No part of any of it is a published specification.** Every fact comes from reading
  what other implementations do and from watching a real controller, so each module
  records which of the two its answers came from.

  ## What this player says it is

  The four facts below are what a controller reads to decide which controls to draw,
  and both the XML of `PiFi.Plex.Companion.Router` and the headers of
  `PiFi.Plex.Companion.Gdm` carry them. **They live here so the two cannot disagree**:
  a player that named one set of capabilities over HTTP and another over UDP would draw
  a different set of controls depending on how the controller found it.
  """

  use Supervisor

  require Logger

  alias PiFi.Settings

  @enabled_key "plex.companion.enabled"

  # **The port is a guess, and the published address is what settles it.** A player
  # names its own port when it tells plex.tv where it is, so any number serves. Of the
  # two implementations that I read, `python-plexapi` assumes 32433 for a player that
  # named none, and the plugin of another project publishes 32500. This takes the
  # second, because that one is a player of music and the other is a library.
  @port 32_500

  # `timeline` is what a controller polls, `playback` is what it commands, and the two
  # play queue names say that this player takes a list and moves through it.
  # `navigation` is absent, and the moduledoc of `PiFi.Plex.Companion.Router` says why.
  @capabilities "timeline,playback,playqueues,playqueues-creation"

  # A player of music holds no screen that a controller draws on, and this is the class
  # that other players of music name.
  @device_class "stb"

  # The two numbers that a controller reads to decide what this player understands.
  # Every implementation that I read names these.
  @protocol "plex"
  @protocol_version "1"

  @doc "The port that this player listens on."
  @spec port() :: pos_integer()
  def port, do: @port

  @doc """
  What this player tells a controller that it can do.

      iex> PiFi.Plex.Companion.capabilities()
      "timeline,playback,playqueues,playqueues-creation"
  """
  @spec capabilities() :: String.t()
  def capabilities, do: @capabilities

  @doc "What kind of player a controller should draw this as."
  @spec device_class() :: String.t()
  def device_class, do: @device_class

  @doc "The protocol that this player speaks."
  @spec protocol() :: String.t()
  def protocol, do: @protocol

  @doc "The version of that protocol."
  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version

  @doc """
  The settings key that says whether a person turned the player on.

      iex> PiFi.Plex.Companion.enabled_key()
      "plex.companion.enabled"
  """
  @spec enabled_key() :: String.t()
  def enabled_key, do: @enabled_key

  @doc """
  Whether a person turned the player on.

  **A device that no person changed leaves it off.** This is the opposite of
  `PiFi.Source.enabled?/1`, and the port is the reason: a source that a person never
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

  `PiFi.Application` calls this after the tree, in the way that it calls
  `PiFi.Peripheral.start_enabled/0`. **A port that another program holds must not
  stop the boot**, and a child of the tree that cannot start would do that.
  """
  @spec start_enabled() :: :ok
  def start_enabled do
    if enabled?(), do: start_listener()

    :ok
  end

  @doc """
  Every address that a controller may reach this player on.

  **A real player publishes each one of them.** Plexamp on a laptop published three on
  a measurement of 2026-09-15: two of its networks and the address of its overlay
  network. A device with one network gives one, and a controller takes the first that
  answers.

  It leaves out the loopback address, which reaches this device from this device alone,
  and every address of IPv6: a connection of plex.tv names a port and a host, and the
  colons of an IPv6 address make an address that no controller parses.
  """
  @spec addresses() :: [String.t()]
  def addresses do
    case :inet.getifaddrs() do
      {:ok, interfaces} -> Enum.flat_map(interfaces, &addresses_of/1)
      {:error, _reason} -> []
    end
  end

  defp addresses_of({_name, options}) do
    options
    |> Keyword.get_values(:addr)
    |> Enum.filter(&reachable?/1)
    |> Enum.map(fn address -> "http://#{:inet.ntoa(address)}:#{@port}" end)
  end

  defp reachable?({127, _b, _c, _d}), do: false

  defp reachable?({a, b, c, d})
       when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d), do: true

  defp reachable?(_address), do: false

  @doc false
  @impl Supervisor
  def init(_options), do: Supervisor.init([], strategy: :one_for_one)

  @doc false
  def start_link(options), do: Supervisor.start_link(__MODULE__, options, name: __MODULE__)

  # **The listener comes first, and the two ways of finding it follow.** Each of those
  # tells a controller where this player is, and a controller that read the address
  # before the port answered would meet nothing. See
  # `PiFi.Plex.Companion.Announcement` and `PiFi.Plex.Companion.Gdm`.
  defp start_listener do
    for child <- [queue(), listener(), announcement(), discovery(), farewell()],
        do: start_child(child)

    :ok
  end

  defp start_child(child) do
    case Supervisor.start_child(__MODULE__, child) do
      {:ok, _pid} ->
        Logger.info("The Plex player started #{inspect(child.id)} on port #{@port}.")

      {:error, :already_present} ->
        Supervisor.restart_child(__MODULE__, child.id)

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning("The Plex player did not start #{inspect(child.id)}: #{inspect(reason)}")
    end

    :ok
  end

  defp stop_listener do
    for id <- [:farewell, :discovery, :announcement, :listener, :queue] do
      Supervisor.terminate_child(__MODULE__, id)
      Supervisor.delete_child(__MODULE__, id)
    end

    :ok
  end

  defp listener do
    %{
      id: :listener,
      start:
        {Bandit, :start_link, [[plug: PiFi.Plex.Companion.Router, port: @port, scheme: :http]]}
    }
  end

  defp announcement do
    %{id: :announcement, start: {PiFi.Plex.Companion.Announcement, :start_link, [[]]}}
  end

  # It answers the controllers that look on the local network rather than in an
  # account. See `PiFi.Plex.Companion.Gdm`.
  defp discovery do
    %{id: :discovery, start: {PiFi.Plex.Companion.Gdm, :start_link, [[]]}}
  end

  # It holds the play queue that a controller named, and the timeline reads it. See
  # `PiFi.Plex.Companion.Queue`.
  defp queue do
    %{id: :queue, start: {PiFi.Plex.Companion.Queue, :start_link, [[]]}}
  end

  # **It is last on purpose, so that it stops first.** A supervisor stops its children
  # in reverse order, and this one answers the poll that a controller is holding open
  # while the listener behind it is still up. See `PiFi.Plex.Companion.Farewell`.
  defp farewell do
    %{id: :farewell, start: {PiFi.Plex.Companion.Farewell, :start_link, [[]]}}
  end
end
