defmodule MyHiFi.Plex.Sync.Checkpoint do
  @moduledoc """
  How far the read of a Plex library has reached.

  A large library takes more than an hour to read, and this device stops often. The
  read writes this every few pages, and a read that begins after an interruption
  continues from it rather than asking the server for the whole library again. See
  `MyHiFi.Plex.Sync.Library`.

  ## What it carries, and why each part

  - `started_at` is the time that the **first** read of this pass began.
    `MyHiFi.Plex.Sync.Library.remove_unseen/1` removes each row that the pass did not
    see, and it reads `last_seen_at` against this time. A read that continued with a
    new time would call every row of the part already read a row that the server no
    longer has, and it would remove the lot.
  - `kind`, `section` and `offset` say where to ask next.

  **`section` is the one part that `MyHiFi.Jellyfin.Sync.Checkpoint` has no need of.**
  A Jellyfin read asks for the artists of the whole server, and a Plex server holds a
  section for each library, so a household with a section of records and a section of
  audiobooks has two to read through. The point therefore names which one it stopped
  in.

  ## Why one setting and not a resource

  It is one row of a key and a value, and `MyHiFi.Settings` already has that shape. A
  resource would bring a table, a migration and a snapshot for four fields that no
  page reads and no query joins.

  ## Why it writes every tenth page and not every page

  A page is 50 items, so ten pages is 500 and an interruption costs about 30 seconds
  of reading. **Every page would write this over a thousand times for each read**, and
  this device runs for years on an SD card. `Ash.bulk_create/4` writes every row of
  the library over the same read, so 125 writes beside that is nothing.
  """

  require Logger

  alias MyHiFi.Plex.Server
  alias MyHiFi.Settings

  @key "plex_library_checkpoint"
  @every 10

  @doc """
  The point that a read reached, or `:error` for a read with none.

  A value that this module cannot read gives `:error` as well, and the read then
  starts from the beginning. A point is a convenience and never a thing to stop for.
  """
  @spec read() ::
          {:ok,
           %{
             started_at: DateTime.t(),
             kind: atom(),
             section: String.t(),
             offset: non_neg_integer()
           }}
          | :error
  def read do
    with {:ok, %{value: value}} <- Settings.fetch(@key),
         {:ok, %{"started_at" => at, "kind" => kind} = point} <- Jason.decode(value),
         {:ok, started_at, _offset} <- DateTime.from_iso8601(at),
         true <- kind in kinds(),
         section when is_binary(section) <- point["section"],
         offset when is_integer(offset) <- point["offset"] do
      {:ok,
       %{
         started_at: started_at,
         kind: String.to_existing_atom(kind),
         section: section,
         offset: offset
       }}
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
  @spec write(DateTime.t(), atom(), String.t(), non_neg_integer()) :: :ok
  def write(started_at, kind, section, offset) do
    if due?(offset) do
      value =
        Jason.encode!(%{
          started_at: DateTime.to_iso8601(started_at),
          kind: to_string(kind),
          section: section,
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
  raises nothing, for the reason that `write/4` gives.
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
    Logger.warning("The read of the Plex library could not note where it is: #{inspect(reason)}")

    :ok
  end
end
