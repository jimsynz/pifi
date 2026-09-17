defmodule PiFi.Playback.Facet.DestroyOrphans do
  @moduledoc """
  Remove every `PiFi.Playback.Facet` that no item holds.

  A sync that drops the last station of a country leaves that country behind. The
  `by_key` read hides such a row already, so this reclaims the rows and nothing more.
  A fill calls it when it finishes.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias PiFi.Playback.Facet

  @impl true
  def run(_input, _options, _context) do
    result =
      Facet
      |> Ash.Query.filter(not exists(item_facets, true))
      |> Ash.bulk_destroy!(:destroy, %{},
        strategy: :stream,
        return_records?: true,
        return_errors?: true
      )

    {:ok, length(result.records || [])}
  end
end
