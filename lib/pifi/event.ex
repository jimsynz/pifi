defmodule PiFi.Event do
  @moduledoc """
  What one part of the firmware tells the others.

  Each part talks through Phoenix PubSub, and no part calls another part directly.
  Every message is a struct with named fields, and nothing sends a bare tuple or a
  map.

  There are six topics. `:player` carries what the player does, and
  `PiFi.Event.Player` defines those structs. `:source` carries a change to the
  content of a source, and `PiFi.Event.Source` defines those. `:device` carries the
  state of the hardware that no person changes, and `PiFi.Event.Device` defines
  those. `:view`, `:input` and `:hint` belong to the device screen and the knob, and
  they arrive with that work.
  """

  @topics [:player, :source, :device, :view, :input, :hint]

  @typedoc "The topics that a part subscribes to."
  @type topic :: :player | :source | :device | :view | :input | :hint

  @typedoc "Any event of any topic."
  @type t :: struct()

  @doc "The topics that this firmware uses."
  @spec topics() :: [topic()]
  def topics, do: @topics

  @doc """
  Receive each event of one topic.

  The caller then gets each event as a message in its own mailbox.
  """
  @spec subscribe(topic()) :: :ok | {:error, term()}
  def subscribe(topic) when topic in @topics do
    Phoenix.PubSub.subscribe(PiFi.PubSub, to_string(topic))
  end

  @doc """
  Stop listening to a topic.

  **A process that answers one request and then serves another must stop listening.**
  `PiFi.Plex.Companion.Router` waits for an event of the player while it holds a poll
  of a controller, and the process that holds it serves the next request of that
  connection. A subscription that stayed would put the events of the player in the
  mailbox of a request that wants none.
  """
  @spec unsubscribe(atom()) :: :ok
  def unsubscribe(topic) when topic in @topics do
    Phoenix.PubSub.unsubscribe(PiFi.PubSub, to_string(topic))
  end

  @doc """
  Send one event to each subscriber of a topic.
  """
  @spec publish(topic(), t()) :: :ok
  def publish(topic, %_{} = event) when topic in @topics do
    Phoenix.PubSub.broadcast(PiFi.PubSub, to_string(topic), event)
  end
end
