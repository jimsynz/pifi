defmodule MyHiFi.Cache.Attachment.Changes.DetachRecord do
  @moduledoc """
  Removes the join rows of a record that is going.

  The join holds no key to the record, because no column of the cache names a
  resource, so the database cannot do this. Only the host knows its own type, so the
  host carries this change on its destroy action:

      destroy :destroy do
        primary? true
        change {MyHiFi.Cache.Attachment.Changes.DetachRecord, type: "show"}
      end

  **It removes the join rows and not the entries.** An entry is shared: one cover
  serves a show and each of its episodes, so taking the entries of a show would take
  a picture that 30 episodes still use.

  It also needs to take nothing. The cache reclaims by least recently used, and an
  entry that no record names any more is the coldest thing in it, so the eviction
  takes it exactly when the space is wanted. Nothing about a cache needs a file to go
  at the moment that its last reader does.

  The work happens before the action, inside the transaction of the destroy, so a
  destroy that fails leaves the rows as they were.
  """

  use Ash.Resource.Change

  require Ash.Query
  require Logger

  alias MyHiFi.Cache.Attachment

  @impl true
  def change(changeset, options, _context) do
    type = Keyword.fetch!(options, :type)

    Ash.Changeset.before_action(changeset, fn changeset ->
      detach(type, changeset.data.id)
      changeset
    end)
  end

  defp detach(type, id) do
    Attachment
    |> Ash.Query.filter(record_type == ^type and record_id == ^id)
    |> Ash.bulk_destroy(:destroy, %{}, strategy: :stream, return_errors?: true)
    |> case do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{errors: errors} ->
        Logger.warning("Could not detach #{type} #{id} from the cache: #{inspect(errors)}")
        :ok
    end
  end
end
