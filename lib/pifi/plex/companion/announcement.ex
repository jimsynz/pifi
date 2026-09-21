defmodule PiFi.Plex.Companion.Announcement do
  @moduledoc """
  Keeps the registration of this player current on plex.tv.

  **A controller reads the address of a player from the account, and it reads nothing
  else.** A registration that says the wrong thing is worse than none: a controller
  draws the player, a person presses it, and the command reaches an address that answers
  nothing.

  Two things go out of date, and this publishes the registration again for each one.

  - **The name.** A person renames their device, and `PiFi.Device.Identity` publishes
    `PiFi.Event.Device.IdentityChanged` for it. plex.tv holds the name that it was
    given at the last publish, so a household with two of these would read the old name
    on one of them for ever.
  - **The address.** A board takes its address from the network, and that address moves.
    This therefore publishes at each start as well, so a device that was given another
    address corrects the account when it comes back.
  - **The network.** `PiFi.Application` starts this at the boot, and Wi-Fi is not up
    then. `PiFi.Plex.Companion.addresses/0` reads the interfaces of the machine, so the
    publish of a cold boot carried no address at all and the account then held a player
    that a telephone could not reach. Nothing corrected it, because the two events above
    are both rare. `PiFi.Event.Device.NetworkChanged` is the one that says an address
    arrived, and this publishes again for it.

  A publish of the same address costs one request of plex.tv and it changes nothing, so
  a start that needed no correction is no worse for making one.

  ## A publish that fails must not take the player with it

  This is a child of `PiFi.Plex.Companion`, which is `:one_for_one` with the default
  intensity, so three failures in five seconds and the supervisor gives up — and it
  takes the listener, the discovery responder and the play queue with it. Nothing starts
  them again, because `start_enabled/0` runs once at the boot.

  So `publish_to_account/0` answers for every way a publish can fail, and not only for
  the `{:error, _}` that `PiFi.Plex.Server` returns. The device answers a controller that
  already knows where it is whatever plex.tv says, so a publish that did not land costs
  a person nothing until they open a controller that has never seen this device.

  **It publishes nothing for a device that a person has not made a player**, and it
  asks plex.tv nothing to find that out. The account holds no row for such a device, so
  `PiFi.Plex.Server.registered_as_player?/0` reads the settings and this stops there.
  """

  use GenServer

  require Logger

  alias PiFi.Event
  alias PiFi.Event.Device.IdentityChanged
  alias PiFi.Event.Device.NetworkChanged
  alias PiFi.Plex.Companion
  alias PiFi.Plex.Server

  @doc false
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @doc false
  @impl GenServer
  def init(_options) do
    # **A person who turns the player off must not kill a publish in the middle of
    # it.** This process reads the settings and then reaches plex.tv, and a stop that
    # arrived in the middle of the read took the connection of the database with it. A
    # process that traps the exit reads the stop as a message instead, so the publish
    # that is in flight finishes and the stop follows it.
    Process.flag(:trap_exit, true)

    :ok = Event.subscribe(:device)

    {:ok, nil, {:continue, :publish}}
  end

  @doc false
  @impl GenServer
  def handle_continue(:publish, state) do
    publish()

    {:noreply, state}
  end

  @doc false
  @impl GenServer
  def handle_info(%IdentityChanged{}, state) do
    publish()

    {:noreply, state}
  end

  # **An address that arrives after the boot is the common case, not the rare one.**
  # See the module documentation.
  def handle_info(%NetworkChanged{}, state) do
    publish()

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # **A publish that fails must not stop the player.** The device answers a controller
  # that already knows where it is, whatever plex.tv says, so a network that is not there
  # costs a person nothing until they open a controller that has never seen this device.
  defp publish do
    if Server.registered_as_player?(), do: publish_to_account()

    :ok
  end

  # **A raise here used to take the whole Plex player down with it.** This process is a
  # child of `PiFi.Plex.Companion`, which is `:one_for_one` with the default intensity,
  # so three failures in five seconds and the supervisor gives up — and it takes the
  # listener, the discovery responder and the play queue with it. Nothing starts them
  # again, because `start_enabled/0` runs once at the boot, so a person's Plex player
  # would quietly stop existing until the next reboot.
  #
  # `Server.publish_player/1` answers `{:error, _}` for the faults it knows about and
  # raises for the rest: `Req` raises on a plug that is not there, and a pool can exit
  # under it. The clause above says a publish that fails must not stop the player, and
  # these two make that true of every way it can fail.
  defp publish_to_account do
    case Server.publish_player(Companion.addresses()) do
      :ok ->
        Logger.info("plex.tv holds the address of this player.")

      {:error, reason} ->
        Logger.warning("plex.tv did not take the address of this player: #{inspect(reason)}")
    end

    :ok
  rescue
    exception ->
      Logger.warning("plex.tv did not take the address of this player: #{inspect(exception)}")

      :ok
  catch
    :exit, reason ->
      Logger.warning("plex.tv did not take the address of this player: #{inspect(reason)}")

      :ok
  end
end
