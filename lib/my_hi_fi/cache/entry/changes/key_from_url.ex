defmodule MyHiFi.Cache.Entry.Changes.KeyFromUrl do
  @moduledoc """
  Names an entry after the address that it came from, when a caller named nothing.

  The name is a hash, so no text from a service reaches the file system. A caller that
  holds one thing for each address therefore needs no key of its own, and a caller
  that wants its own key keeps it.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _options, _context) do
    case Ash.Changeset.get_attribute(changeset, :entry_key) do
      nil -> Ash.Changeset.force_change_attribute(changeset, :entry_key, key(changeset))
      _named -> changeset
    end
  end

  defp key(changeset) do
    changeset
    |> Ash.Changeset.get_argument(:url)
    |> then(&:crypto.hash(:sha256, &1 || ""))
    |> Base.encode16(case: :lower)
  end
end
