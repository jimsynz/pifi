defmodule MyHiFi.Plex.Companion.Announcement do
  @moduledoc """
  Keeps the registration of this player current on plex.tv.

  **A controller reads the address of a player from the account, and it reads nothing
  else.** A registration that says the wrong thing is worse than none: a controller
  draws the player, a person presses it, and the command reaches an address that answers
  nothing.

  Two things go out of date, and this publishes the registration again for each one.

  - **The name.** A person renames their device, and `MyHiFi.Device.Identity` publishes
    `MyHiFi.Event.Device.IdentityChanged` for it. plex.tv holds the name that it was
    given at the last publish, so a household with two of these would read the old name
    on one of them for ever.
  - **The address.** A board takes its address from the network, and that address moves.
    This therefore publishes at each start as well, so a device that was given another
    address corrects the account when it comes back.

  A publish of the same address costs one request of plex.tv and it changes nothing, so
  a start that needed no correction is no worse for making one.

  **It publishes nothing for a device that a person has not made a player**, and it
  asks plex.tv nothing to find that out. The account holds no row for such a device, so
  `MyHiFi.Plex.Server.registered_as_player?/0` reads the settings and this stops there.
  """

  use GenServer

  require Logger

  alias MyHiFi.Event
  alias MyHiFi.Event.Device.IdentityChanged
  alias MyHiFi.Plex.Companion
  alias MyHiFi.Plex.Server

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

  def handle_info(_message, state), do: {:noreply, state}

  # **A publish that fails must not stop the player.** The device answers a controller
  # that already knows where it is, whatever plex.tv says, so a network that is not there
  # costs a person nothing until they open a controller that has never seen this device.
  defp publish do
    if Server.registered_as_player?(), do: publish_to_account()

    :ok
  end

  defp publish_to_account do
    case Server.publish_player(Companion.addresses()) do
      :ok ->
        Logger.info("plex.tv holds the address of this player.")

      {:error, reason} ->
        Logger.warning("plex.tv did not take the address of this player: #{inspect(reason)}")
    end

    :ok
  end
end
