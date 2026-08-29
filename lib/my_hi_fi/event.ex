defmodule MyHiFi.Event do
  @moduledoc """
  What one part of the firmware tells the others.

  Each part talks through Phoenix PubSub, and no part calls another part directly.
  Every message is a struct with named fields, and nothing sends a bare tuple or a
  map.

  There are six topics. `:player` carries what the player does, and
  `MyHiFi.Event.Player` holds those structs. `:source` carries a change to the
  content of a source, and `MyHiFi.Event.Source` holds those. `:device` carries the
  state of the hardware that no person changes, and `MyHiFi.Event.Device` holds
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
    Phoenix.PubSub.subscribe(MyHiFi.PubSub, to_string(topic))
  end

  @doc """
  Send one event to each subscriber of a topic.
  """
  @spec publish(topic(), t()) :: :ok
  def publish(topic, %_{} = event) when topic in @topics do
    Phoenix.PubSub.broadcast(MyHiFi.PubSub, to_string(topic), event)
  end
end
