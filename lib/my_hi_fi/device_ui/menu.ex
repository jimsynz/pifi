defmodule MyHiFi.DeviceUi.Menu do
  @rows 100

  @moduledoc """
  The tree that a person moves through on the device.

  This is the click wheel of the device: a level holds rows, a row leads to another
  level or it plays, and the whole tree comes from what the firmware already knows.
  `MyHiFi.DeviceUi` holds where a person is, and this module builds one level at a
  time.

  ## The tree

      Root
      ├── Now playing              leaves the menu
      ├── <each source in use>     the branches that the source names
      │   └── Countries            one branch, from `c:MyHiFi.Source.roots/0`
      │       └── NZ               one facet value
      │           └── RNZ National a track, and a press plays it
      ├── Playlists
      │   └── Friday
      │       └── Teardrop         a track of that playlist
      ├── Play queue
      │   └── Teardrop             a row of the queue
      └── Standby

  **The source names its own branches, so this module knows no source.** A source that
  a person added appears here with the branches, the order and the facts that it names,
  and nothing in this file changes. That is the same rule that `MyHiFiWeb.BrowseLive`
  follows, and the two read the same queries.

  ## A press on a track plays the level that it is in

  A person who presses a track means "play this, and then the rest of this list", which
  is what a press on a row of the web page means. The level therefore carries the
  identifiers of its tracks, and a press names the place that they pressed. See
  `MyHiFi.Playback.play/2`.

  **A level therefore needs no row for "play everything".** A person who wants a whole
  album presses its first track, and the rest of the album follows it into the queue.

  ## What the root holds of the device itself

  **Standby, and nothing else.** The issue that asked for this menu asked for the
  system management functions as well, and standby is the one that a person wants
  while they stand at the stereo. The address of a Wi-Fi network, the name of the
  device and the key of a service each need a keyboard, and the web interface is where
  a person types. A menu of four buttons that held those would be a menu that a person
  reads past to reach the music.

  ## How many rows a level holds

  #{@rows} at most. A person moves through a level with four buttons or with one knob, and
  a level of a whole country is not something that a person moves through: the web page
  is where a library of 4377 albums is read. The rows are the first #{@rows} in the order
  that the source names.
  """

  require Ash.Query

  alias MyHiFi.Playback
  alias MyHiFi.Playback.Item
  alias MyHiFi.Source

  @typedoc "Where a person is in the tree."
  @type place ::
          :root
          | :playlists
          | {:playlist, Ash.UUID.t()}
          | :queue
          | {:source, module()}
          | {:branch, module(), String.t()}
          | {:facet, module(), String.t()}
          | {:container, module(), Ash.UUID.t()}

  @typedoc "What a press on one row does."
  @type action ::
          {:open, place()}
          | {:play, [Ash.UUID.t()], non_neg_integer()}
          | :close
          | :standby

  @typedoc "One row of a level."
  @type row :: %{
          title: String.t(),
          subtitle: String.t() | nil,
          kind: :open | :play | :do,
          action: action()
        }

  @typedoc "One level of the tree."
  @type level :: %{title: String.t(), place: place(), rows: [row()]}

  @doc """
  The level of one place.

  A place that this device no longer holds, such as a playlist that a person removed
  from a browser while the menu was open, gives the root. A person then reads a level
  that is there rather than an empty one.
  """
  @spec level(place()) :: level()
  def level(place) do
    case rows(place) do
      {:ok, title, rows} -> %{title: title, place: place, rows: rows}
      :error -> %{title: title(:root), place: :root, rows: root_rows()}
    end
  end

  @doc """
  The name of one place, for a screen to draw as the head of the level.
  """
  @spec title(place()) :: String.t()
  def title(:root), do: "Menu"
  def title(:playlists), do: "Playlists"
  def title(:queue), do: "Play queue"
  def title({:source, module}), do: module.title()
  def title({:branch, _module, name}), do: name
  def title({:facet, _module, value}), do: value

  def title({:playlist, id}) do
    case Playback.get_playlist(id) do
      {:ok, playlist} -> to_string(playlist.name)
      {:error, _reason} -> "Playlists"
    end
  end

  def title({:container, _module, id}) do
    case Playback.get_item(id) do
      {:ok, item} -> item.title
      {:error, _reason} -> "Menu"
    end
  end

  defp rows(:root), do: {:ok, title(:root), root_rows()}

  defp rows({:source, module} = place) do
    rows =
      Enum.map(module.roots(), fn {name, _listing} ->
        %{
          title: name,
          subtitle: nil,
          kind: :open,
          action: {:open, {:branch, module, name}}
        }
      end)

    {:ok, title(place), rows}
  end

  defp rows({:branch, module, name} = place) do
    case Enum.find(module.roots(), fn {found, _listing} -> found == name end) do
      {_name, listing} -> {:ok, title(place), of_listing(module, listing)}
      nil -> :error
    end
  end

  # The items that carry one facet value. `MyHiFiWeb.BrowseLive` reads the same query,
  # and the source names the order of the rows under a facet.
  defp rows({:facet, module, value} = place) do
    inside = Source.inside(module, nil)

    query =
      Item
      |> Ash.Query.filter(source == ^Source.slug(module) and exists(facets, value == ^value))
      |> Ash.Query.sort(inside[:sort] || [])

    {:ok, title(place), of_listing(module, %{query: query, kind: :item})}
  end

  # A container opens into the items whose `parent_id` names it, and the source names
  # the order: an album reads its tracks by number, and a show reads its episodes by
  # date with the newest first.
  defp rows({:container, module, id} = place) do
    slug = Source.slug(module)

    case Playback.get_item(id) do
      {:ok, %{kind: :container, source: ^slug} = item} ->
        inside = Source.inside(module, item)

        query =
          Item
          |> Ash.Query.filter(parent_id == ^item.id)
          |> Ash.Query.sort(inside[:sort] || [])

        {:ok, title(place), of_listing(module, %{query: query, kind: :item})}

      _other ->
        :error
    end
  end

  defp rows(:playlists) do
    rows =
      Playback.list_playlists!(load: [:entry_count])
      |> Enum.map(fn playlist ->
        %{
          title: to_string(playlist.name),
          subtitle: tracks(playlist.entry_count),
          kind: :open,
          action: {:open, {:playlist, playlist.id}}
        }
      end)

    {:ok, title(:playlists), rows}
  end

  defp rows({:playlist, id} = place) do
    case Playback.get_playlist(id) do
      {:ok, playlist} ->
        items =
          playlist.id
          |> Playback.playlist_entries!(load: [:item])
          |> Enum.map(& &1.item)

        {:ok, title(place), of_tracks(items)}

      {:error, _reason} ->
        :error
    end
  end

  # The queue is the one level that a person reads to go back to a track that played.
  defp rows(:queue) do
    items =
      Playback.queue!()
      |> Enum.map(& &1.item_id)
      |> items_by_ids()

    {:ok, title(:queue), of_tracks(items)}
  end

  defp rows(_place), do: :error

  # **Now playing is the first row, because it is the way out.** A person who opened the
  # menu by mistake presses the button that they are already on.
  defp root_rows do
    now_playing = [%{title: "Now playing", subtitle: nil, kind: :do, action: :close}]

    sources =
      Enum.map(Source.enabled(), fn module ->
        %{
          title: module.title(),
          subtitle: nil,
          kind: :open,
          action: {:open, {:source, module}}
        }
      end)

    now_playing ++
      sources ++
      [
        %{title: "Playlists", subtitle: nil, kind: :open, action: {:open, :playlists}},
        %{title: "Play queue", subtitle: nil, kind: :open, action: {:open, :queue}},
        %{title: "Standby", subtitle: nil, kind: :do, action: :standby}
      ]
  end

  # A branch of a source lists facets or items, and a facet leads to the items that
  # carry it.
  defp of_listing(module, %{kind: :facet, query: query}) do
    query
    |> Ash.Query.limit(@rows)
    |> Ash.read!()
    |> Enum.map(fn facet ->
      value = to_string(facet.value.value)

      %{
        title: value,
        subtitle: nil,
        kind: :open,
        action: {:open, {:facet, module, value}}
      }
    end)
  end

  defp of_listing(module, %{query: query}) do
    query
    |> Ash.Query.limit(@rows)
    |> Ash.read!()
    |> of_items(module)
  end

  defp of_items(items, module) do
    ids = items |> Enum.filter(&(&1.kind == :track)) |> Enum.map(& &1.id)

    Enum.map(items, fn item -> of_item(item, module, ids) end)
  end

  # **A playlist and a queue carry tracks, so a level of one names no source.** A
  # container of another source cannot lead anywhere here: the place of a container
  # names the source that owns the tree, and neither of these two is a tree.
  defp of_tracks(items) do
    items
    |> Enum.filter(&(&1.kind == :track))
    |> of_items(nil)
  end

  defp of_item(%{kind: :container} = item, module, _ids) do
    %{
      title: item.title,
      subtitle: item.subtitle,
      kind: :open,
      action: {:open, {:container, module, item.id}}
    }
  end

  defp of_item(item, _module, ids) do
    %{
      title: item.title,
      subtitle: item.subtitle,
      kind: :play,
      action: {:play, ids, Enum.find_index(ids, &(&1 == item.id))}
    }
  end

  # A queue row and a playlist entry both name an item, and a row whose item is gone
  # from the catalogue draws nothing.
  defp items_by_ids([]), do: []

  defp items_by_ids(ids) do
    by_id = ids |> Playback.items_by_ids!() |> Map.new(&{&1.id, &1})

    ids |> Enum.map(&Map.get(by_id, &1)) |> Enum.reject(&is_nil/1)
  end

  defp tracks(1), do: "1 track"
  defp tracks(count), do: "#{count} tracks"
end
