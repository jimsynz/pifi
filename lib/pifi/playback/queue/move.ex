defmodule PiFi.Playback.Queue.Move do
  @moduledoc """
  Move the mark to the row before or after the one that plays.

  **This is a person pressing a control**, so a repeat of one does not apply: somebody
  who presses next has asked for a different track, and a control that did nothing would
  read as a device that stopped listening to them. `PiFi.Playback.Queue.Advance` is the
  end of a track, and that one honours it.

  The queue holds the order, and a source takes no part in it. This is why
  `PiFi.Source` needs no `next/1` and no `previous/1`. Which row is beside the one that
  plays depends on shuffle and on repeat, and `PiFi.Playback.Queue.Walk` is the one
  place that decides.
  """

  use Ash.Resource.Actions.Implementation

  alias PiFi.Playback.Queue.Walk

  @impl true
  def run(input, _options, _context) do
    with {:ok, playing} <- Walk.playing(),
         {:ok, wanted} <- beside(input.arguments.direction) do
      {:ok, _left} = Ash.update(playing, %{playing?: false}, action: :set_playing)
      Ash.update(wanted, %{playing?: true}, action: :set_playing)
    end
  end

  defp beside(:next), do: Walk.after_playing(false)
  defp beside(:previous), do: Walk.before_playing()
end
