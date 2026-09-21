defmodule PiFi.Plex.Companion.Farewell do
  @moduledoc """
  Tells a Plex controller that the player stopped, while the device is going down.

  **A controller polls, and nothing pushes to it.** `PiFi.Plex.Companion.Router` answers
  `/player/timeline/poll`, and a poll of `wait=1` holds for five seconds waiting for the
  player to say something. A reboot killed the listener with that poll still open, so
  Plexamp kept the last answer it had, which said `playing`, and it drew a track that
  had stopped on a device that was no longer there.

  This process exists to answer that last poll. Its `terminate/2` marks the player as
  leaving, wakes every poll that is waiting, and gives them a moment to write their
  answer before the listener behind them goes.

  ## The order is the whole design

  `PiFi.Application` starts `PiFi.Player` before `PiFi.Plex.Companion`, so the companion
  terminates **first** and the listener is gone by the time the player could say
  anything. Nothing the player does on the way out can reach a Plex controller.

  A supervisor stops its children in reverse order, so this is the **last** child that
  `PiFi.Plex.Companion` starts and therefore the first one it stops. The listener, the
  announcement and the discovery responder are all still up while this runs, which is
  the one window in the whole shutdown where an answer can still reach a telephone.

  ## Why it says stopped rather than reading the player

  `PiFi.Player` is still playing at this moment: it is further down the tree and it has
  not been told to stop yet. A poll that read the real state would answer `playing`,
  which is the bug. **What is true in a second is what a controller needs now**, so
  `saying_goodbye?/0` is a flag and the router answers the idle state for it.

  The flag lives in `:persistent_term` because the process that sets it is about to go,
  and a poll that read it through a `GenServer.call` would meet a dead process at
  exactly the moment it matters. A write of a persistent term is expensive, and this
  writes one, once, on the way to a reboot.
  """

  use GenServer

  alias PiFi.Event
  alias PiFi.Event.Player, as: Events

  @key {__MODULE__, :saying_goodbye?}

  # How long the pending polls get to write their answer. A poll wakes on the message
  # below, reads a map and renders a few hundred bytes of XML, so this is generous. It
  # is also time added to every shutdown, which is why it is not a second.
  @flush 250

  @doc """
  Whether the device is on its way down, and a controller should be told `stopped`.

  `PiFi.Plex.Companion.Router` reads this in the place of the state of the player.
  """
  @spec saying_goodbye?() :: boolean()
  def saying_goodbye?, do: :persistent_term.get(@key, false)

  @doc false
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @doc false
  @impl GenServer
  def init(_options) do
    # A shutdown reaches `terminate/2` for a process that traps exits, and for no other.
    Process.flag(:trap_exit, true)

    # A device that stopped and started again is not leaving, and the term survives the
    # process. The listener starts and stops with this, so a person who turns the Plex
    # player off and on again would otherwise answer `stopped` for ever.
    :persistent_term.put(@key, false)

    {:ok, nil}
  end

  @doc false
  @impl GenServer
  def terminate(_reason, state) do
    :persistent_term.put(@key, true)

    # The polls are waiting on this topic, and any event of it wakes them. The player
    # itself publishes one of these on the way out as well, but that happens after the
    # listener has gone, which is the reason this module exists.
    Event.publish(:player, %Events.Stopped{reason: :shutting_down})

    Process.sleep(@flush)

    {:noreply, state}
  end
end
