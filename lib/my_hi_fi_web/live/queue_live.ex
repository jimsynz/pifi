defmodule MyHiFiWeb.QueueLive do
  @moduledoc """
  What plays now, and what plays next.

  `MyHiFi.Playback.Queue` already had every action that this page needs, and nothing
  called them. A person could fill the queue by pressing a track, and after that they
  could neither see the queue nor change it.

  ## Two reads, joined here

  A queue row lives in ETS and an item lives in SQLite, so **Ash cannot join the two**,
  and `MyHiFi.Playback.Queue` stores an item identifier rather than a relationship.
  Reading one item per row would mean one query per row, so this reads the rows in
  order, reads all of their items in a single query, and pairs them up. See the `by_ids`
  action on `MyHiFi.Playback.Item`.

  **The rows decide the order, never the items.** The item query returns them in
  whatever order the data layer likes.

  ## Pressing a row keeps the rest of the queue

  Pressing a row of a list means "play this, then the rest of the list", and
  `MyHiFi.Playback.play/2` takes the whole list plus the position that was pressed. This
  page passes the identifiers already in the queue, so only the playing mark moves.
  Passing a single identifier would discard everything else.

  ## What a person can change

  They can remove a row, move a row, and empty the queue.

  **Moving a row does not change what is playing.** It changes what comes next. See
  `MyHiFi.Playback.Queue.Order`.

  **The playing row can be removed like any other**, and the player carries on playing
  it. `MyHiFi.Playback.Queue.Remove` leaves the playing mark to its caller, and removing
  the playing row means "do not play this again" rather than "stop".
  """

  use MyHiFiWeb, :live_view

  alias MyHiFi.Artwork
  alias MyHiFi.Event
  alias MyHiFi.Playback

  import MyHiFiWeb.ItemList, only: [cover: 1]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Event.subscribe(:player)

    {:ok, socket |> assign(:page_title, "Play queue") |> load()}
  end

  # Any player event can move the playing mark, and a track that ends moves it with
  # nobody pressing anything. A queue holds few rows, so reading them all is cheaper
  # than working out which events matter.
  @impl Phoenix.LiveView
  def handle_info(%_{} = _event, socket), do: {:noreply, load(socket)}

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
  def handle_event("move", %{"id" => id, "position" => position}, socket) do
    case Integer.parse(position) do
      {position, ""} -> _result = Playback.reorder_queue(id, position)
      _other -> :ok
    end

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

      <ul :if={@rows != []} class="divide-y divide-edge">
        <li :for={{row, index} <- Enum.with_index(@rows)} id={"queue-#{row.id}"}>
          <.queue_row row={row} index={index} last?={index == length(@rows) - 1} />
        </li>
      </ul>
    </div>
    """
  end

  attr(:row, :map, required: true)
  attr(:index, :integer, required: true)
  attr(:last?, :boolean, required: true)

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

      <button
        type="button"
        id={"up-#{@row.id}"}
        phx-click="move"
        phx-value-id={@row.id}
        phx-value-position={@index - 1}
        disabled={@index == 0}
        aria-label="Move up"
        class="control rounded-lg p-1 disabled:opacity-30"
      >
        <.icon name="hero-chevron-up-mini" class="size-4" />
      </button>

      <button
        type="button"
        id={"down-#{@row.id}"}
        phx-click="move"
        phx-value-id={@row.id}
        phx-value-position={@index + 1}
        disabled={@last?}
        aria-label="Move down"
        class="control rounded-lg p-1 disabled:opacity-30"
      >
        <.icon name="hero-chevron-down-mini" class="size-4" />
      </button>

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

    assign(socket, :rows, rows_with_items(rows, items))
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
