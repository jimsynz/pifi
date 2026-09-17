defmodule PiFi.Plex.Companion.Queue do
  @moduledoc """
  Remembers the play queue of the server that a controller asked this player to play.

  **A controller draws its screen from a play queue, and not from a track.** It sends
  `playMedia` with the queue that it made, or it asks this player to make one, and then
  it reads the timeline to find out what happened. A timeline that named the track and
  not the queue gave it nothing that it could use: a person cast a playlist to this
  device on 2026-09-15, the music played, and the screen of their telephone showed a
  spinner for as long as they watched.

  **The queue belongs to the server and the list of this device does not.**
  `PiFi.Playback.Queue` is a list of rows on the card, which every source shares and
  which a person makes by pressing things on the device. A play queue is a row of the
  Plex server with an identifier that a controller knows. The two hold the same tracks
  when a controller started the music, and they have nothing else in common, so this
  holds the second one and leaves the first alone.

  ## It forgets by itself

  A person plays a station of the radio, or a track of a library that no controller
  named, and the queue that this holds says nothing about that. `of/1` therefore
  answers for a track that the queue holds and nothing for any other, so a timeline
  names a queue only while the music is of that queue.
  """

  use Agent

  alias PiFi.Plex.Server

  @doc false
  def start_link(_options), do: Agent.start_link(fn -> nil end, name: __MODULE__)

  @doc """
  Keep the queue that a controller named or asked for.
  """
  @spec keep(Server.queue()) :: :ok
  def keep(%{id: id} = queue) when is_integer(id) do
    if running?(), do: Agent.update(__MODULE__, fn _held -> queue end)

    :ok
  end

  def keep(_queue), do: :ok

  @doc """
  Forget the queue, because the music is no longer of it.
  """
  @spec forget() :: :ok
  def forget do
    if running?(), do: Agent.update(__MODULE__, fn _held -> nil end)

    :ok
  end

  @doc """
  What a timeline says about one track, or an empty list for a track of no queue.

  `ratingKey` of the track names the row, and a track that this queue does not hold
  gives nothing: a person who played something else on the device is not in the queue
  that a controller made.
  """
  @spec of(String.t() | nil) :: [{String.t(), term()}]
  def of(nil), do: []

  def of(ref) do
    case held() do
      %{id: id, rows: rows, version: version} ->
        attributes(id, version, Map.get(rows, to_string(ref)))

      nil ->
        []
    end
  end

  # **A device that a person has not made a player holds no queue**, and this starts
  # with the listener. A caller that read it anyway would stop with `:noproc`, and the
  # timeline of a player that is starting must answer whatever else is true.
  defp held do
    if running?(), do: Agent.get(__MODULE__, & &1)
  end

  defp running?, do: is_pid(Process.whereis(__MODULE__))

  defp attributes(_id, _version, nil), do: []

  defp attributes(id, version, item_id) do
    [
      {"playQueueID", id},
      {"playQueueItemID", item_id},
      {"containerKey", "/playQueues/#{id}"}
    ] ++ named("playQueueVersion", version)
  end

  defp named(_name, nil), do: []
  defp named(name, value), do: [{name, value}]
end
