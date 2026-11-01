defmodule PiFiWeb.PlaylistLive do
  @moduledoc """
  LiveView for creating, browsing, editing, and playing playlists.

  The queue can be saved as a playlist. Playlist rows can be reordered or removed,
  and playing a row continues with the remaining rows.
  """

  use PiFiWeb, :live_view

  alias PiFi.Artwork
  alias PiFi.Event
  alias PiFi.Event.Player, as: Events
  alias PiFi.Playback
  alias PiFi.Playback.Playlist
  alias PiFi.Source

  import PiFiWeb.ItemList, only: [cover: 1]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Event.subscribe(:player)

    {:ok, assign(socket, asked: MapSet.new(), naming?: false)}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, socket.assigns.live_action, params)}
  end

  @impl Phoenix.LiveView
  def handle_info(%Events.Started{}, socket), do: {:noreply, reload(socket)}
  def handle_info(%Events.Stopped{}, socket), do: {:noreply, reload(socket)}
  def handle_info(%Events.Failed{}, socket), do: {:noreply, reload(socket)}
  def handle_info(%_{}, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("name", _params, socket), do: {:noreply, assign(socket, :naming?, true)}

  @impl Phoenix.LiveView
  def handle_event("cancel_name", _params, socket),
    do: {:noreply, assign(socket, :naming?, false)}

  @impl Phoenix.LiveView
  def handle_event("keep_queue", %{"name" => name}, socket) do
    case Playback.queue!() do
      [] ->
        {:noreply,
         put_flash(socket, :error, "The queue is empty. Add some tracks before saving it.")}

      rows ->
        keep(socket, name, Enum.map(rows, & &1.item_id))
    end
  end

  @impl Phoenix.LiveView
  def handle_event("rename", %{"name" => name}, socket) do
    case Playback.rename_playlist(socket.assigns.playlist, name) do
      {:ok, renamed} ->
        {:noreply,
         socket
         |> assign(:playlist, renamed)
         |> put_flash(:info, "Renamed to #{renamed.name}.")
         |> reload()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal(reason))}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("remove_playlist", %{"id" => id}, socket) do
    with {:ok, playlist} <- Playback.get_playlist(id),
         :ok <- Playback.destroy_playlist(playlist) do
      {:noreply,
       socket
       |> put_flash(:info, "Deleted #{playlist.name}. The tracks are still available.")
       |> push_navigate(to: ~p"/playlists")}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, refusal(reason))}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("play_playlist", %{"id" => id}, socket) do
    case Playback.playlist_item_ids!(id) do
      [] ->
        {:noreply, put_flash(socket, :error, "That playlist is empty.")}

      ids ->
        play(socket, ids, 0)
    end
  end

  @impl Phoenix.LiveView
  def handle_event("queue_playlist", %{"id" => id}, socket) do
    case Playback.playlist_item_ids!(id) do
      [] ->
        {:noreply, put_flash(socket, :error, "That playlist is empty.")}

      ids ->
        case Playback.append_to_queue(ids) do
          {:ok, _rows} ->
            {:noreply, put_flash(socket, :info, "#{length(ids)} tracks are in the queue.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, refusal(reason))}
        end
    end
  end

  # A press on a row means "play this, and then the rest of the playlist", which is the
  # rule that a press on a track of an album follows.
  @impl Phoenix.LiveView
  def handle_event("play", %{"id" => id}, socket) do
    ids = Enum.map(socket.assigns.rows, & &1.item_id)

    case Enum.find_index(ids, &(&1 == id)) do
      nil -> {:noreply, reload(socket)}
      index -> play(socket, ids, index)
    end
  end

  @impl Phoenix.LiveView
  def handle_event("remove", %{"id" => id}, socket) do
    _result = Playback.remove_playlist_entry(id)

    {:noreply, reload(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("move", %{"id" => id, "position" => position}, socket)
      when is_integer(position) do
    _result = Playback.reorder_playlist_entry(id, position)

    {:noreply, reload(socket)}
  end

  @impl Phoenix.LiveView
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <div id="playlists" class="glass sheen rounded-xl p-4">
      <div class="mb-3 flex items-center gap-2">
        <.link navigate={~p"/"} id="back" aria-label="Back" class="control rounded-lg p-1.5">
          <.icon name="ph-caret-left" class="size-4" />
        </.link>
        <h2 class="grow text-xs uppercase tracking-[0.18em] text-ink-faint">Playlists</h2>

        <button
          :if={not @naming?}
          type="button"
          id="keep-queue"
          phx-click="name"
          class="control rounded-lg px-2 py-1 text-xs"
        >
          Save the queue
        </button>
      </div>

      <form :if={@naming?} id="keep-queue-form" phx-submit="keep_queue" class="mb-3">
        <p class="mb-2 text-sm text-ink-dim">
          The queue has {tracks(@queue_count)}. Name the playlist and everything in the
          queue goes into it.
        </p>

        <div class="flex items-center gap-2">
          <input
            type="text"
            id="playlist-name"
            name="name"
            maxlength="100"
            required
            autocomplete="off"
            placeholder="Friday"
            class="control grow rounded-lg px-3 py-2 text-sm"
          />
          <button type="submit" id="keep" class="control rounded-lg px-3 py-2 text-sm">Save</button>
          <button
            type="button"
            id="cancel-name"
            phx-click="cancel_name"
            class="control rounded-lg px-3 py-2 text-sm"
          >
            Cancel
          </button>
        </div>
      </form>

      <p :if={@playlists == []} id="playlists-empty" class="text-sm text-ink-dim">
        No playlists yet. Play something, then save the queue as a playlist.
      </p>

      <ul :if={@playlists != []} class="divide-y divide-edge">
        <li :for={playlist <- @playlists} id={"playlist-#{playlist.id}"}>
          <div class="flex w-full min-w-0 items-center gap-2 py-1">
            <.link
              navigate={~p"/playlists/#{playlist.id}"}
              id={"open-#{playlist.id}"}
              class="group flex min-w-0 grow items-center gap-3 py-2 text-left"
            >
              <.playlist_mark playlist={playlist} />
              <span class="min-w-0 grow">
                <span class="block truncate text-ink group-hover:text-accent">{playlist.name}</span>
                <span class="block truncate text-xs text-ink-faint">
                  {tracks(playlist.entry_count)}
                </span>
              </span>
            </.link>

            <button
              type="button"
              id={"play-playlist-#{playlist.id}"}
              phx-click="play_playlist"
              phx-value-id={playlist.id}
              aria-label={"Play #{playlist.name}"}
              class="control rounded-lg p-1"
            >
              <.icon name="ph-play" class="size-4" />
            </button>

            <button
              type="button"
              id={"queue-playlist-#{playlist.id}"}
              phx-click="queue_playlist"
              phx-value-id={playlist.id}
              aria-label={"Add #{playlist.name} to the queue"}
              class="control rounded-lg p-1"
            >
              <.icon name="ph-queue" class="size-4" />
            </button>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div id="playlist" class="glass sheen rounded-xl p-4">
      <div class="mb-3 flex items-center gap-2">
        <.link
          navigate={~p"/playlists"}
          id="back"
          aria-label="Back"
          class="control rounded-lg p-1.5"
        >
          <.icon name="ph-caret-left" class="size-4" />
        </.link>
        <.playlist_mark playlist={@playlist} class="size-4 shrink-0 text-ink-faint" />
        <h2 id="playlist-name" class="grow truncate text-xs uppercase tracking-[0.18em] text-ink-faint">
          {@playlist.name}
        </h2>

        <button
          type="button"
          id="play-playlist"
          phx-click="play_playlist"
          phx-value-id={@playlist.id}
          aria-label={"Play #{@playlist.name}"}
          class="control rounded-lg p-1.5"
        >
          <.icon name="ph-play" class="size-4" />
        </button>

        <button
          :if={Playlist.mine?(@playlist)}
          type="button"
          id="remove-playlist"
          phx-click="remove_playlist"
          phx-value-id={@playlist.id}
          aria-label={"Remove #{@playlist.name}"}
          class="control rounded-lg p-1.5"
        >
          <.icon name="ph-trash" class="size-4" />
        </button>
      </div>

      <p
        :if={not Playlist.mine?(@playlist)}
        id="playlist-source"
        class="mb-3 text-sm text-ink-dim"
      >
        {from(@playlist)} keeps this playlist. Change it there and PiFi follows.
      </p>

      <form
        :if={Playlist.mine?(@playlist)}
        id="rename-form"
        phx-submit="rename"
        class="mb-3 flex items-center gap-2"
      >
        <input
          type="text"
          id="new-name"
          name="name"
          value={@playlist.name}
          maxlength="100"
          required
          autocomplete="off"
          aria-label="Playlist name"
          class="control grow rounded-lg px-3 py-2 text-sm"
        />
        <button type="submit" id="rename" class="control rounded-lg px-3 py-2 text-sm">
          Rename
        </button>
      </form>

      <p :if={@rows == []} id="playlist-empty" class="text-sm text-ink-dim">
        This playlist is empty.
      </p>

      <ul
        :if={@rows != []}
        id="playlist-rows"
        phx-hook={Playlist.mine?(@playlist) && "DragToReorder"}
        class="divide-y divide-edge"
      >
        <li :for={row <- @rows} id={"entry-#{row.id}"} data-row={row.id}>
          <.entry row={row} playing_id={@playing_id} mine?={Playlist.mine?(@playlist)} />
        </li>
      </ul>
    </div>
    """
  end

  # The mark beside the name of a playlist. A playlist that a person made draws a list.
  # One that a service gave draws the mark of that service, so a person reads where it
  # came from without opening it.
  attr(:playlist, :map, required: true)
  attr(:class, :any, default: "size-5 shrink-0 text-ink-faint")

  defp playlist_mark(assigns) do
    assigns = assign(assigns, :mark, mark_of(assigns.playlist))

    ~H"""
    <.source_icon :if={@mark} name={@mark} class={@class} />
    <.icon :if={is_nil(@mark)} name="ph-list-bullets" class={@class} />
    """
  end

  defp mark_of(playlist) do
    with false <- Playlist.mine?(playlist),
         {:ok, module} <- Source.from_slug(playlist.source) do
      module.icon()
    else
      _other -> nil
    end
  end

  # A source that this firmware no longer holds still names itself in the row, so a
  # person reads something rather than a blank.
  defp from(playlist) do
    case Source.from_slug(playlist.source) do
      {:ok, module} -> module.title()
      {:error, _reason} -> playlist.source
    end
  end

  attr(:row, :map, required: true)
  attr(:playing_id, :any, required: true)
  attr(:mine?, :boolean, required: true)

  defp entry(assigns) do
    assigns = assign(assigns, :artwork, Artwork.thumbnail_path(assigns.row.item.artwork))

    ~H"""
    <div class="flex w-full min-w-0 items-center gap-2 py-1">
      <button
        type="button"
        id={"play-#{@row.id}"}
        phx-click="play"
        phx-value-id={@row.item_id}
        class="group flex min-w-0 grow items-center gap-3 text-left"
      >
        <.cover path={@artwork} class="size-8" />
        <span class="min-w-0 grow">
          <span
            data-title
            class={[
              "block truncate group-hover:text-accent",
              if(@row.item_id == @playing_id, do: "text-accent", else: "text-ink")
            ]}
          >
            {@row.item.title}
          </span>
          <span :if={@row.item.subtitle} class="block truncate text-xs text-ink-faint">
            {@row.item.subtitle}
          </span>
        </span>
      </button>

      <span :if={@row.item_id == @playing_id} class="shrink-0 text-accent" aria-label="Playing now">
        <.icon name="ph-speaker-high" class="size-4" />
      </span>

      <span
        :if={@mine?}
        id={"drag-#{@row.id}"}
        data-drag-handle
        aria-label="Drag to reorder"
        class="control shrink-0 cursor-grab touch-none rounded-lg p-1 active:cursor-grabbing"
      >
        <.icon name="ph-rows" class="size-4" />
      </span>

      <button
        :if={@mine?}
        type="button"
        id={"remove-#{@row.id}"}
        phx-click="remove"
        phx-value-id={@row.id}
        aria-label="Remove from the playlist"
        class="control rounded-lg p-1"
      >
        <.icon name="ph-x" class="size-4" />
      </button>
    </div>
    """
  end

  defp load(socket, :index, _params) do
    socket
    |> PiFiWeb.Shell.put_page("Playlists")
    |> assign(:playlists, Playback.list_playlists!(load: [:entry_count]))
    |> assign(:queue_count, Playback.queue_count!())
  end

  defp load(socket, :show, %{"id" => id}) do
    case Playback.get_playlist(id) do
      {:ok, playlist} ->
        rows = Playback.playlist_entries!(playlist.id, load: [item: [:artwork]])

        socket
        |> PiFiWeb.Shell.put_page(to_string(playlist.name))
        |> assign(:playlist, playlist)
        |> assign(:rows, rows)
        |> assign(:playing_id, playing_id())
        |> ask_for_pictures(rows)

      {:error, _reason} ->
        socket
        |> put_flash(:error, "No such playlist.")
        |> push_navigate(to: ~p"/playlists")
    end
  end

  defp reload(socket), do: load(socket, socket.assigns.live_action, params(socket))

  defp params(%{assigns: %{playlist: playlist}}), do: %{"id" => playlist.id}
  defp params(_socket), do: %{}

  # **Nothing else asks for the picture of a track**, and a playlist of tracks draws
  # one for each row. See `PiFiWeb.QueueLive`, which follows the same two rules: one
  # read for a whole list, and one ask for one address.
  defp ask_for_pictures(socket, rows) do
    urls =
      rows
      |> Enum.map(& &1.item.artwork)
      |> Enum.reject(&(is_nil(&1) or MapSet.member?(socket.assigns.asked, &1)))
      |> Enum.uniq()

    Artwork.ensure(urls)

    assign(socket, :asked, MapSet.union(socket.assigns.asked, MapSet.new(urls)))
  end

  defp keep(socket, name, item_ids) do
    with {:ok, playlist} <- Playback.create_playlist(name),
         {:ok, _entries} <- Playback.add_to_playlist(playlist.id, item_ids) do
      {:noreply,
       socket
       |> assign(:naming?, false)
       |> put_flash(:info, "#{playlist.name} has #{tracks(length(item_ids))}.")
       |> reload()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, refusal(reason))}
    end
  end

  defp play(socket, ids, index) do
    case Playback.play(ids, %{playing_index: index}) do
      {:ok, :ok} -> {:noreply, reload(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, refusal(reason))}
    end
  end

  # The mark of the row comes from the queue, because the queue is what plays. A
  # playlist that a person has not played therefore marks no row.
  defp playing_id do
    case Playback.queue_playing!() do
      nil -> nil
      row -> row.item_id
    end
  end

  defp tracks(1), do: "1 track"
  defp tracks(count), do: "#{count} tracks"

  # A name that another playlist already carries is the one refusal that a person
  # meets, so it says so in words. Anything else is a fault of the device.
  defp refusal(%Ash.Error.Invalid{errors: errors}) do
    if Enum.any?(errors, &match?(%Ash.Error.Changes.InvalidAttribute{field: :name}, &1)) do
      "That name is already taken, or it's empty."
    else
      "Could not save the playlist. Please check its name and try again."
    end
  end

  defp refusal(_reason), do: "Could not update the playlist. Please try again."
end
