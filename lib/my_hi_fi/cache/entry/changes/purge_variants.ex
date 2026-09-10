defmodule MyHiFi.Cache.Entry.Changes.PurgeVariants do
  @moduledoc """
  Removes the variants of an entry before the entry goes.

  A thumbnail names its picture in `variant_of_blob_id`, and the migration declares a
  foreign key on that column. **A destroy of the picture alone therefore fails**, and
  `MyHiFi.Cache.Entry.Prune` then reports that it could not remove every entry and
  frees nothing. A thumbnail of a picture that is absent is waste, so the two go
  together.

  A variant has no variant of its own, so this stops after one step.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias MyHiFi.Cache

  @impl true
  def change(changeset, _options, _context) do
    Ash.Changeset.before_action(changeset, &purge_variants/1)
  end

  # The work is a hook before the action, and the verifier of Ash reads this callback
  # and not the hook. `AshStorage.BlobResource.Changes.PurgeFile` sits in the same
  # action and does the same thing, for the same reason.
  @impl true
  def atomic(changeset, options, context), do: {:ok, change(changeset, options, context)}

  defp purge_variants(changeset) do
    Cache.Entry
    |> Ash.Query.filter(variant_of_blob_id == ^changeset.data.id)
    |> Cache.purge_all()
    |> case do
      :ok ->
        changeset

      {:error, errors} ->
        Ash.Changeset.add_error(changeset,
          field: :id,
          message: "has variants that could not go: #{inspect(errors)}"
        )
    end
  end
end
