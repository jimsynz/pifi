defmodule PiFi.Playback.Item.Changes.KeepPlaceOnly do
  @moduledoc """
  Write the place of an item that keeps one, and of no other.

  A person who stops half way through an episode wants to go on from there next week.
  A person who stops half way through a song does not want to hear the second half of
  it tomorrow, and `keeps_place?` of the item is what tells the two apart.

  This holds the rule, and not the player, because the player tells every item where a
  person stopped. A caller cannot then get it wrong, and a source that fills the
  catalogue decides the answer one time.

  A track that keeps no place still goes on from where a person paused it. The player
  holds that place while the track is the one that plays, and this only stops it from
  reaching the row.
  """

  use Ash.Resource.Change

  import Ash.Expr

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    if changeset.data.keeps_place? do
      changeset
    else
      changeset
      |> Ash.Changeset.clear_change(:position_ms)
      |> Ash.Changeset.clear_change(:position_bytes)
    end
  end

  # The row decides, so one statement can hold the rule and the update stays atomic. A
  # column keeps what it holds when the item keeps no place.
  @impl Ash.Resource.Change
  def atomic(_changeset, _opts, _context) do
    {:atomic,
     %{
       position_ms: expr(if(keeps_place?, do: ^atomic_ref(:position_ms), else: position_ms)),
       position_bytes:
         expr(if(keeps_place?, do: ^atomic_ref(:position_bytes), else: position_bytes))
     }}
  end
end
