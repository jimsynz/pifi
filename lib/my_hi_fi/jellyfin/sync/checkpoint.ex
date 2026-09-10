defmodule MyHiFi.Jellyfin.Sync.Checkpoint do
  @moduledoc """
  How far the read of a Jellyfin library has reached.

  A read of 67,508 items takes about 88 minutes, and this device stops often. The read
  writes this every few pages, and a read that begins after an interruption continues
  from it rather than asking the server for the whole library again. See
  `MyHiFi.Jellyfin.Sync.Library`.

  ## What it carries, and why each part

  - `started_at` is the time that the **first** read of this pass began.
    `MyHiFi.Jellyfin.Sync.Library.remove_unseen/1` removes each row that the pass did
    not see, and it reads `last_seen_at` against this time. A read that continued with
    a new time would call every row of the part already read a row that the server no
    longer has, and it would remove the lot.
  - `kind` and `offset` say where to ask next.

  ## Why one setting and not a resource

  It is one row of a key and a value, and `MyHiFi.Settings` already has that shape.
  A resource would bring a table, a migration and a snapshot for three fields that no
  page reads and no query joins.

  ## Why it writes every tenth page and not every page

  A page is 50 items, so ten pages is 500 and an interruption costs about 30 seconds of
  reading. **Every page would write this 1,247 times for each read**, and this device
  runs for years on an SD card. `Ash.bulk_create/4` writes 67,508 rows over the same
  read, so 125 writes beside that is nothing, and 1,247 is a cost with no answer to
  show for it.
  """

  require Logger

  alias MyHiFi.Jellyfin.Server
  alias MyHiFi.Settings

  @key "jellyfin_library_checkpoint"
  @every 10

  @doc """
  The point that a read reached, or `:error` for a read with none.

  A value that this module cannot read gives `:error` as well, and the read then starts
  from the beginning. A point is a convenience and never a thing to stop for.
  """
  @spec read() ::
          {:ok, %{started_at: DateTime.t(), kind: atom(), offset: non_neg_integer()}} | :error
  def read do
    with {:ok, %{value: value}} <- Settings.fetch(@key),
         {:ok, %{"started_at" => at, "kind" => kind, "offset" => offset}} <- Jason.decode(value),
         {:ok, started_at, _offset} <- DateTime.from_iso8601(at),
         true <- kind in kinds() do
      {:ok, %{started_at: started_at, kind: String.to_existing_atom(kind), offset: offset}}
    else
      _other -> :error
    end
  end

  @doc """
  Note where the read has reached, for every tenth page.

  `offset` decides whether this writes at all, so a caller gives every page and this
  sets the rate. A caller that decided for itself would keep the number in two places.

  **It raises nothing.** A point that no write reached costs a read of the library
  again, and that is a smaller thing than a read that stops because it could not write
  a note to itself.
  """
  @spec write(DateTime.t(), atom(), non_neg_integer()) :: :ok
  def write(started_at, kind, offset) do
    if due?(offset) do
      value =
        Jason.encode!(%{
          started_at: DateTime.to_iso8601(started_at),
          kind: to_string(kind),
          offset: offset
        })

      case Settings.put(@key, value) do
        {:ok, _setting} -> :ok
        {:error, reason} -> forgotten(reason)
      end
    else
      :ok
    end
  end

  @doc """
  Take the point away, because the read finished.

  A point that stayed would send the next read into the middle of the library. It
  raises nothing, for the reason that `write/3` gives.
  """
  @spec forget() :: :ok
  def forget do
    case Settings.fetch(@key) do
      {:ok, setting} ->
        case Settings.delete(setting) do
          :ok -> :ok
          {:ok, _setting} -> :ok
          {:error, reason} -> forgotten(reason)
        end

      {:error, _reason} ->
        :ok
    end
  end

  @doc "The name that `MyHiFi.Settings` keeps this under."
  @spec key() :: String.t()
  def key, do: @key

  defp due?(offset), do: rem(div(offset, Server.page_size()), @every) == 0

  defp kinds, do: ["artists", "albums", "tracks"]

  defp forgotten(reason) do
    Logger.warning(
      "The read of the Jellyfin library could not note where it is: #{inspect(reason)}"
    )

    :ok
  end
end
