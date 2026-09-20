defmodule PiFi.Playback.Queue.Replace do
  @moduledoc """
  Put a new list in the queue.

  A person who presses a track of a list means "play this, and then the rest of the
  list", so the whole list goes in and the row that they pressed takes the mark.

  **It writes in bulk.** The queue is in SQLite now, and a list of 500 tracks was 500
  inserts and 500 deletes on an SD card. `Ash.bulk_create/4` writes one statement for
  the batch, and the destroy above it writes one more.
  """

  use Ash.Resource.Actions.Implementation

  alias PiFi.Playback.Queue

  @impl true
  def run(input, _options, _context) do
    item_ids = input.arguments.item_ids
    playing_index = input.arguments.playing_index

    Ash.bulk_destroy!(Queue, :destroy, %{})

    %{status: :success, records: rows} =
      item_ids
      |> Enum.with_index()
      |> Enum.map(fn {item_id, index} ->
        %{item_id: item_id, position: index, playing?: index == playing_index}
      end)
      |> Ash.bulk_create!(Queue, :create, return_records?: true, sorted?: true)

    {:ok, rows}
  end
end
