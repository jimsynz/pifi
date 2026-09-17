defmodule PiFi.Playback.Queue.Replace do
  @moduledoc """
  Put a new list in the queue.

  A person who presses a track of a list means "play this, and then the rest of the
  list", so the whole list goes in and the row that they pressed takes the mark.
  """

  use Ash.Resource.Actions.Implementation

  alias PiFi.Playback.Queue

  @impl true
  def run(input, _options, _context) do
    item_ids = input.arguments.item_ids
    playing_index = input.arguments.playing_index

    Enum.each(Ash.read!(Queue), &Ash.destroy!/1)

    rows =
      item_ids
      |> Enum.with_index()
      |> Enum.map(fn {item_id, index} ->
        Queue
        |> Ash.Changeset.for_create(:create, %{
          item_id: item_id,
          position: index,
          playing?: index == playing_index
        })
        |> Ash.create!()
      end)

    {:ok, rows}
  end
end
