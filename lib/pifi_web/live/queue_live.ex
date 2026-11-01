defmodule PiFiWeb.QueueLive do
  @moduledoc """
  LiveView for viewing and editing the playback queue.

  Rows can be played, removed, reordered by dragging, shuffled, repeated, or cleared.
  Reordering changes upcoming tracks but does not interrupt the current track.
  """

  use PiFiWeb, :live_view

  alias PiFi.Artwork
  alias PiFi.Event
  alias PiFi.Event.Player, as: Events
  alias PiFi.Playback
  alias PiFi.Playback.Queue.Mode

  import PiFiWeb.ItemList, only: [cover: 1]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Event.subscribe(:player)

    socket =
      socket
      |> PiFiWeb.Shell.put_page("Play queue")
      |> assign(asked: MapSet.new())
      |> load()

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_info(%Events.Started{}, socket), do: {:noreply, load(socket)}
  def handle_info(%Events.Stopped{}, socket), do: {:noreply, load(socket)}
  def handle_info(%Events.Failed{}, socket), do: {:noreply, load(socket)}
  def handle_info(%_{}, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("play", %{"id" => id}, socket) do
    case Enum.find_index(socket.assigns.rows, &(&1.id == id)) do
      nil ->
        {:noreply, load(socket)}

      index ->
        ids = Enum.map(socket.assigns.rows, & &1.item_id)
        _result = Playback.play(ids, %{playing_index: index})

        {:noreply, load(socket)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("remove", %{"id" => id}, socket) do
    _result = Playback.remove_from_queue(id)

    {:noreply, load(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("move", %{"id" => id, "position" => position}, socket)
      when is_integer(position) do
    _result = Playback.reorder_queue(id, position)

    {:noreply, load(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("shuffle", _params, socket) do
    {:ok, :ok} = Playback.shuffle_queue(not socket.assigns.mode.shuffle?)

    {:noreply, refresh(socket)}
  end

  def handle_event("repeat", _params, socket) do
    {:ok, :ok} = Playback.repeat_queue(Mode.after_this(socket.assigns.mode.repeat))

    {:noreply, refresh(socket)}
  end

  def handle_event("clear", _params, socket) do
    {:ok, _count} = Playback.clear_queue()

    {:noreply, socket |> put_flash(:info, "The queue is empty.") |> load()}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div id="queue" class="glass sheen rounded-xl p-4">
      <div class="mb-3 flex items-center gap-2">
        <.link navigate={~p"/"} id="back" aria-label="Back" class="control rounded-lg p-1.5">
          <.icon name="ph-caret-left" class="size-4" />
        </.link>
        <h2 class="grow text-xs uppercase tracking-[0.18em] text-ink-faint">Play queue</h2>

        <button
          :if={@rows != []}
          type="button"
          id="shuffle-queue"
          phx-click="shuffle"
          aria-pressed={to_string(@mode.shuffle?)}
          aria-label={shuffle_label(@mode.shuffle?)}
          class={["control rounded-lg p-1.5", @mode.shuffle? && "control-on"]}
        >
          <.icon name="ph-shuffle" class="size-4" />
        </button>

        <button
          :if={@rows != []}
          type="button"
          id="repeat-queue"
          phx-click="repeat"
          aria-label={repeat_label(@mode.repeat)}
          class={["control rounded-lg p-1.5", @mode.repeat != :off && "control-on"]}
        >
          <.icon name={repeat_icon(@mode.repeat)} class="size-4" />
        </button>

        <button
          :if={@rows != []}
          type="button"
          id="clear-queue"
          phx-click="clear"
          class="control rounded-lg px-2 py-1 text-xs"
        >
          Clear
        </button>
      </div>

      <p :if={@rows == []} id="queue-empty" class="text-sm text-ink-dim">
        Nothing in the queue. Play a track and the rest of its list follows.
      </p>

      <ul
        :if={@rows != []}
        id="queue-rows"
        phx-hook="DragToReorder"
        class="divide-y divide-edge"
      >
        <li :for={row <- @rows} id={"queue-#{row.id}"} data-row={row.id}>
          <.queue_row row={row} />
        </li>
      </ul>
    </div>
    """
  end

  attr(:row, :map, required: true)

  defp queue_row(assigns) do
    assigns = assign(assigns, :artwork, Artwork.thumbnail_path(assigns.row.item.artwork))

    ~H"""
    <div class="flex w-full min-w-0 items-center gap-2 py-1">
      <button
        type="button"
        id={"play-#{@row.id}"}
        phx-click="play"
        phx-value-id={@row.id}
        class="group flex min-w-0 grow items-center gap-3 text-left"
      >
        <.cover path={@artwork} class="size-8" />
        <span class="min-w-0 grow">
          <span
            data-title
            class={[
              "block truncate group-hover:text-accent",
              if(@row.playing?, do: "text-accent", else: "text-ink")
            ]}
          >
            {@row.item.title}
          </span>
          <span :if={@row.item.subtitle} class="block truncate text-xs text-ink-faint">
            {@row.item.subtitle}
          </span>
        </span>
      </button>

      <span :if={@row.playing?} class="shrink-0 text-accent" aria-label="Playing now">
        <.icon name="ph-speaker-high" class="size-4" />
      </span>

      <span
        id={"drag-#{@row.id}"}
        data-drag-handle
        aria-label="Drag to reorder"
        class="control shrink-0 cursor-grab touch-none rounded-lg p-1 active:cursor-grabbing"
      >
        <.icon name="ph-rows" class="size-4" />
      </span>

      <button
        type="button"
        id={"remove-#{@row.id}"}
        phx-click="remove"
        phx-value-id={@row.id}
        aria-label="Remove from the queue"
        class="control rounded-lg p-1"
      >
        <.icon name="ph-x" class="size-4" />
      </button>
    </div>
    """
  end

  defp load(socket) do
    rows = Playback.queue!(load: [item: [:artwork]])

    socket
    |> assign(:rows, rows)
    |> assign(:mode, Playback.queue_mode!())
    |> ask_for_pictures(rows)
  end

  defp refresh(socket), do: load(socket)

  defp shuffle_label(true), do: "Play in the order you made"
  defp shuffle_label(false), do: "Shuffle"

  # **A repeat of one and a repeat of all are different marks**, because a person needs
  # to read which of the three they pressed their way to without pressing again.
  defp repeat_icon(:one), do: "ph-repeat-once"
  defp repeat_icon(_off_or_all), do: "ph-repeat"

  defp repeat_label(:off), do: "Repeat the queue"
  defp repeat_label(:all), do: "Repeat this track"
  defp repeat_label(:one), do: "Stop at the end of the queue"

  # **Nothing else asks for the picture of a track.** `PiFi.Jellyfin.Fill` asks for
  # the picture of a container, because a list of containers draws one, and the player
  # asks for the picture of the track that it starts. This is the one list of tracks
  # that draws a picture, so a queue showed the picture of the tracks that had played
  # and a folder for the rest.
  #
  # **A page asks one time for one address.** `load/1` runs for each event of the
  # player, which is once a second while a track plays, and `PiFi.Artwork.ensure/1`
  # reads the cache for the list that it gets.
  defp ask_for_pictures(socket, rows) do
    urls =
      rows
      |> Enum.map(& &1.item.artwork)
      |> Enum.reject(&(is_nil(&1) or MapSet.member?(socket.assigns.asked, &1)))
      |> Enum.uniq()

    Artwork.ensure(urls)

    assign(socket, :asked, MapSet.union(socket.assigns.asked, MapSet.new(urls)))
  end
end
