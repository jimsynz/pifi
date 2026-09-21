defmodule PiFi.Playback.Queue.NextUp do
  @moduledoc """
  The row that will play when this track ends. It moves no mark.

  `PiFi.Playback.Queue.Advance` answers the same question by making that row the one
  that plays. The player needs the answer while a person is still in the middle of a
  track, so that it can read the audio of that row before it is needed. See
  `PiFi.Player.Prefetch`.

  **It answers what `advance` would**, which means a repeat of one gives the row that is
  already playing. The audio of that row is already on the card, so the prefetch finds
  nothing to do, which is the right answer.
  """

  use Ash.Resource.Actions.Implementation

  alias PiFi.Playback.Queue.Walk

  @impl true
  def run(_input, _options, _context), do: Walk.after_playing(true)
end
