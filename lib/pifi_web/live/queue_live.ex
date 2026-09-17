defmodule PiFiWeb.QueueLive do
  @moduledoc """
  What plays now, and what plays next.

  `PiFi.Playback.Queue` already had every action that this page needs, and nothing
  called them. A person could fill the queue by pressing a track, and after that they
  could neither see the queue nor change it.

  ## Two reads, joined here

  A queue row lives in ETS and an item lives in SQLite, so **Ash cannot join the two**,
  and `PiFi.Playback.Queue` stores an item identifier rather than a relationship.
  Reading one item per row would mean one query per row, so this reads the rows in
  order, reads all of their items in a single query, and pairs them up. See the `by_ids`
  action on `PiFi.Playback.Item`.

  **The rows decide the order, never the items.** The item query returns them in
  whatever order the data layer likes.

  ## Pressing a row keeps the rest of the queue

  Pressing a row of a list means "play this, then the rest of the list", and
  `PiFi.Playback.play/2` takes the whole list plus the position that was pressed. This
  page passes the identifiers already in the queue, so only the playing mark moves.
  Passing a single identifier would discard everything else.

  ## What a person can change

  They can remove a row, move a row, and empty the queue.

  **A person moves a row by dragging its handle**, and the page draws no control that
  moves a row one place. A row of a long queue needs many presses of such a control,
  and a finger on a small screen hits the wrong one of a pair. The `DragToReorder` hook
  of `assets/js/drag_to_reorder.js` reorders the list in the page and sends one `move`
  when the person lets the row go.

  **Moving a row does not change what is playing.** It changes what comes next. See
  `PiFi.Playback.Queue.Order`.

  **The playing row can be removed like any other**, and the player carries on playing
  it. `PiFi.Playback.Queue.Remove` leaves the playing mark to its caller, and removing
  the playing row means "do not play this again" rather than "stop".
  """

  use PiFiWeb, :live_view

  alias PiFi.Artwork
  alias PiFi.Event
  alias PiFi.Event.Player, as: Events
  alias PiFi.Playback

  import PiFiWeb.ItemList, only: [cover: 1]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Event.subscribe(:player)

    socket = socket |> assign(page_title: "Play queue", asked: MapSet.new()) |> load()

    {:ok, socket}
  end

  # **These three move the playing mark, and no other event does.** A track that ends
  # moves it with no person pressing anything, so the page must hear them.
  #
  # `Progress`, `Buffering` and `MetadataChanged` arrive while a track plays, and
  # `load/1` reads every item of the queue in one query. A page that read them all
  # made that query once a second, for a queue of 34 rows, for as long as a person
  # left the page open. `PiFi.AutoStandby` and `PiFi.Peripheral` hold the same
  # rule for the same reason.
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
          <.icon name="hero-chevron-left" class="size-4" />
        </.link>
        <h2 class="grow text-xs uppercase tracking-[0.18em] text-ink-faint">Play queue</h2>

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
        The queue is empty. Play a track and the rest of its list joins the queue.
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
        <.icon name="hero-speaker-wave" class="size-4" />
      </span>

      <span
        id={"drag-#{@row.id}"}
        data-drag-handle
        aria-label="Drag to move this row"
        class="control shrink-0 cursor-grab touch-none rounded-lg p-1 active:cursor-grabbing"
      >
        <.icon name="hero-bars-2-mini" class="size-4" />
      </span>

      <button
        type="button"
        id={"remove-#{@row.id}"}
        phx-click="remove"
        phx-value-id={@row.id}
        aria-label="Remove from the queue"
        class="control rounded-lg p-1"
      >
        <.icon name="hero-x-mark-mini" class="size-4" />
      </button>
    </div>
    """
  end

  # **Two queries, not one per row.** A row whose item has since been removed from the
  # catalogue is skipped: there is nothing to draw for it.
  defp load(socket) do
    rows = Playback.queue!()

    items =
      rows
      |> Enum.map(& &1.item_id)
      |> items_by_id()

    rows = rows_with_items(rows, items)

    socket |> assign(:rows, rows) |> ask_for_pictures(rows)
  end

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

  defp items_by_id([]), do: %{}

  defp items_by_id(ids) do
    ids
    |> Playback.items_by_ids!(load: [:artwork])
    |> Map.new(&{&1.id, &1})
  end

  defp rows_with_items(rows, items) do
    rows
    |> Enum.map(&Map.put(&1, :item, items[&1.item_id]))
    |> Enum.reject(&is_nil(&1.item))
  end
end
