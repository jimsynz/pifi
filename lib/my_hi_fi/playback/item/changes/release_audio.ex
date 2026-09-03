defmodule MyHiFi.Playback.Item.Changes.ReleaseAudio do
  @moduledoc """
  Lets an eviction take the audio of a track that goes.

  `MyHiFi.Player.Download` writes each file with `keep?`, which no eviction may take.
  Two things take that mark off: `c:MyHiFi.Source.finished/1` when a track reaches its
  end, and `MyHiFi.Player.release_file/1` when a person leaves a track that keeps no
  place. **A row that goes reaches neither of them.** The file would then hold the card
  for ever, and nothing could name it again, because the key of the entry is the
  identifier of the row.

  A container holds no audio of its own, so this reads the kind first. A track that the
  cache does not hold gives `:ok` as well: `MyHiFi.Player.Download.release/1` reads the
  cache and answers for a key that it does not know.
  """

  use Ash.Resource.Change

  alias MyHiFi.Player.Download

  @impl true
  def change(changeset, _options, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      release(changeset.data)

      changeset
    end)
  end

  defp release(%{kind: :track, id: id}), do: Download.release(id)
  defp release(_item), do: :ok
end
