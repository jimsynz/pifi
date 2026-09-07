defmodule MyHiFiWeb.ItemList do
  @moduledoc """
  What a page needs to draw a list of `MyHiFi.Playback.Item` and play from it.

  `MyHiFiWeb.BrowseLive` and `MyHiFiWeb.SearchLive` both draw such a list, and a row of
  one is the same row on both. This module holds the rows and the controls, so a change
  to a row reaches each page.

  ## How a page uses it

      use MyHiFiWeb, :live_view

      on_mount MyHiFiWeb.ItemList
      import MyHiFiWeb.ItemList, only: [row: 1, count: 1]

  `on_mount/1` subscribes to the player and to the sources, assigns `:playing`, and
  answers the `play` and the `favourite` events and every event of the player. A page
  therefore holds none of that.

  ## A list that changed while nobody looked

  A source reads a service behind the page, so what a container holds changes while a
  person is elsewhere. `MyHiFi.Event.Source.Changed` says so, and this hook reads the
  list again for it.

  **A device in standby reads nothing.** `MyHiFiWeb.Layouts` draws no list at all in
  standby, so a read then costs the card and the cores and gives no person anything.
  One query of a browse page touched 38 MB of page cache on this board, which is why
  `config/target.exs` holds the SQLite cache down, and standby is the moment that the
  device is quiet in. This hook keeps `:stale?` instead, and it reads the list on the
  way out of standby.

  A read on the way back is one read, whatever the number of events that arrived, and
  it clears the mark before it asks, so a second event of one wake asks for nothing.

  ## Why hooks and not a `use` macro

  A macro writes its clauses where the `use` stands, and a page writes clauses of
  `handle_event/3` and `handle_info/2` of its own. The compiler then reports that the
  clauses of one function are not together, and `mix check` treats that as an error.
  `Phoenix.LiveView.attach_hook/4` adds a clause that runs before the page, and it makes
  no such trouble. `MyHiFiWeb.BrowseLive` writes out the clause of `Cinder.UrlSync` for
  the same reason.

  ## What a page must hold

  `:source` names the source that the rows belong to, and `:collection_id` names the
  collection that a mark refreshes. A page that draws no collection holds `nil` there,
  and this hook then reads nothing.
  """

  use MyHiFiWeb, :html

  alias MyHiFi.Artwork
  alias MyHiFi.Event
  alias MyHiFi.Event.Player, as: Events
  alias MyHiFi.Playback
  alias MyHiFi.Playback.Item

  import Phoenix.LiveView,
    only: [attach_hook: 4, connected?: 1, put_flash: 3]

  require Ash.Query

  # The list that a person is looking at goes in the queue, so next and previous move
  # through what they see. A longer list than this is more than a person steps through,
  # and the whole of a country would be a read of every row of it.
  @queue_limit 500

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Event.subscribe(:player)
      Event.subscribe(:source)
    end

    socket =
      socket
      |> Phoenix.Component.assign(:playing, playing(Playback.state!()))
      |> Phoenix.Component.assign(:stale?, false)
      |> attach_hook(:item_list_events, :handle_event, &event/3)
      |> attach_hook(:item_list_info, :handle_info, &info/2)

    {:cont, socket}
  end

  attr :path, :string, default: nil
  attr :class, :string, default: "size-8"
  attr :icon_class, :string, default: "size-4"

  @doc """
  The picture of a container, with a folder behind it.

  **The folder is not a choice of the caller, and the picture is not certain.**
  `MyHiFi.Artwork.thumbnail_path/1` builds the address without reading the cache, so a
  list costs no query to draw and no row knows whether its picture is there. A picture
  that the cache does not hold answers 404, the browser takes the image away, and the
  folder behind it stays.

  `loading="lazy"` is what holds the cost down on a long list: a browser asks for the
  rows that a person can see, and not for the hundred of a page.

  `data-cover` is what `assets/js/cover.js` reads to take a broken picture away. **An
  `onerror` attribute cannot do it**, because the content security policy of
  `MyHiFiWeb.Router` names no `script-src` and therefore takes `'self'`, which blocks
  an inline handler. The first version of this used one, and a person saw the mark that
  a browser draws for a picture that it could not read.
  """
  def cover(assigns) do
    ~H"""
    <span class={[
      "relative flex shrink-0 items-center justify-center overflow-hidden rounded",
      @class
    ]}>
      <.icon name="hero-folder" class={[@icon_class, "text-ink-faint"]} />
      <img
        :if={@path}
        src={@path}
        alt=""
        loading="lazy"
        data-cover
        class="absolute inset-0 size-full object-cover"
      />
    </span>
    """
  end

  attr :row, :any, required: true
  attr :kind, :atom, default: :item
  attr :playing, :any, default: nil
  attr :source, :any, required: true

  @doc """
  One row of a list.

  A facet opens and never plays. An item opens when it is a container, and it plays when
  it is a track.
  """
  def row(%{kind: :facet} = assigns) do
    ~H"""
    <button
      type="button"
      id={"open-#{@row.id}"}
      phx-click="open"
      phx-value-id={@row.id}
      class="group flex w-full min-w-0 items-center gap-3 py-1 text-left"
    >
      <.icon name="hero-folder" class="size-4 shrink-0 text-ink-faint" />
      <span class="min-w-0 grow truncate text-ink group-hover:text-accent">
        {to_string(@row.value.value)}
      </span>
      <.count of={@row.item_count} />
      <.icon
        name="hero-chevron-right-mini"
        class="size-4 shrink-0 text-ink-faint group-hover:text-accent"
      />
    </button>
    """
  end

  def row(%{row: %{kind: :container}} = assigns) do
    assigns = assign(assigns, :artwork, Artwork.thumbnail_path(Map.get(assigns.row, :artwork)))

    ~H"""
    <div class="flex w-full min-w-0 items-center gap-2">
      <button
        type="button"
        id={"open-#{@row.id}"}
        phx-click="open"
        phx-value-id={@row.id}
        class="group flex min-w-0 grow items-center gap-3 py-1 text-left"
      >
        <.cover path={@artwork} class="size-8" />
        <span class="min-w-0 grow truncate text-ink group-hover:text-accent">{@row.title}</span>
        <.count of={@row.child_count} />
        <.icon
          name="hero-chevron-right-mini"
          class="size-4 shrink-0 text-ink-faint group-hover:text-accent"
        />
      </button>
      <.favourite row={@row} />
    </div>
    """
  end

  def row(assigns) do
    assigns = assign(assigns, :status, status_of(assigns.playing, assigns.source, assigns.row))

    ~H"""
    <div class="flex w-full min-w-0 items-center gap-2">
      <button
        type="button"
        id={"play-#{@row.id}"}
        phx-click="play"
        phx-value-id={@row.id}
        aria-current={@status && "true"}
        class="group flex min-w-0 grow items-center gap-3 py-1 text-left"
      >
        <span class={[
          "control flex size-8 shrink-0 items-center justify-center rounded-full",
          if(@status, do: "control-on", else: "group-hover:text-accent")
        ]}>
          <span :if={@status == :playing} class="meter" aria-hidden="true">
            <span /><span /><span />
          </span>
          <.icon :if={@status == :paused} name="hero-pause-mini" class="size-4" />
          <.icon
            :if={@status == :buffering}
            name="hero-arrow-path-mini"
            class="size-4 motion-safe:animate-spin"
          />
          <.icon :if={is_nil(@status)} name="hero-play-mini" class="size-4" />
        </span>

        <span class="min-w-0 grow">
          <span :if={@status} class="block text-[0.65rem] uppercase tracking-[0.18em] text-accent">
            {status_text(@status)}
          </span>
          <span class={[
            "block truncate",
            if(@status, do: "font-medium text-accent", else: "text-ink group-hover:text-accent")
          ]}>
            {@row.title}
          </span>
          <span :if={@row.subtitle} class="block truncate text-xs text-ink-faint">
            {@row.subtitle}
          </span>
        </span>
      </button>
      <.favourite row={@row} />
    </div>
    """
  end

  attr :of, :integer, required: true

  @doc """
  How many rows a container holds.

  It tells a person whether the row is worth opening. A container that holds nothing
  shows no badge, because 0 is a thing that a person reads and then acts on, and there
  is nothing to act on.
  """
  def count(assigns) do
    ~H"""
    <span
      :if={@of > 0}
      class="numerals shrink-0 rounded-full bg-edge px-2 py-0.5 text-[0.7rem] text-ink-faint"
    >
      {@of}
    </span>
    """
  end

  attr :row, :any, required: true

  # A station is a track that a person marks, and a show is a container that they
  # subscribe to. One control serves both, and an episode carries no mark of its own.
  defp favourite(assigns) do
    ~H"""
    <button
      :if={markable?(@row)}
      type="button"
      id={"favourite-#{@row.id}"}
      phx-click="favourite"
      phx-value-id={@row.id}
      aria-pressed={to_string(@row.favourite? == true)}
      aria-label="Favourite"
      class={[
        "flex size-9 shrink-0 items-center justify-center rounded-full",
        if(@row.favourite?, do: "text-accent", else: "text-ink-faint hover:text-ink")
      ]}
    >
      <.icon name={if @row.favourite?, do: "hero-star-solid", else: "hero-star"} class="size-5" />
    </button>
    """
  end

  # An episode belongs to a show, and a person subscribes to the show.
  defp markable?(%Item{kind: :container}), do: true
  defp markable?(%Item{parent_id: nil}), do: true
  defp markable?(_row), do: false

  # A person means "play this, and then the rest of the list", so the list that they see
  # goes in the queue and the row that they pressed takes the mark.
  defp event("play", %{"id" => id}, socket) do
    ids = queue_ids(socket, id)

    with {:ok, item} <- Playback.get_item(id),
         {:ok, :ok} <- Playback.play(ids, %{playing_index: Enum.find_index(ids, &(&1 == id))}) do
      {:halt,
       socket
       |> Phoenix.Component.assign(:playing, %{item_id: item.id, status: :buffering})
       |> put_flash(:info, "Playing #{item.title}.")}
    else
      {:error, reason} ->
        {:halt, put_flash(socket, :error, "Could not play that: #{inspect(reason)}")}
    end
  end

  # **The list that a person sees is the queue that they get**, in the order that they
  # see it. `:list_query` holds the sort and the filters that Cinder read, so a person
  # who sorted an album by date hears it that way. The head of the collection is not a
  # row of the list, so this takes no identifier: the whole list goes in, and the first
  # track plays.
  defp event("play_collection", _params, socket) do
    case queue_ids(socket, nil) do
      [] ->
        {:halt, put_flash(socket, :error, "There is nothing here to play.")}

      ids ->
        play_all(socket, ids)
    end
  end

  defp event("favourite", %{"id" => id}, socket) do
    with {:ok, item} <- Playback.get_item(id),
         {:ok, _item} <- mark(item) do
      {:halt, Cinder.Refresh.refresh_table(socket, socket.assigns.collection_id)}
    else
      {:error, reason} ->
        {:halt, put_flash(socket, :error, "Could not do that: #{inspect(reason)}")}
    end
  end

  defp event(_name, _params, socket), do: {:cont, socket}

  defp play_all(socket, [first | _rest] = ids) do
    with {:ok, item} <- Playback.get_item(first),
         {:ok, :ok} <- Playback.play(ids, %{playing_index: 0}) do
      {:halt,
       socket
       |> Phoenix.Component.assign(:playing, %{item_id: item.id, status: :buffering})
       |> put_flash(:info, "Playing #{length(ids)} tracks.")}
    else
      {:error, reason} ->
        {:halt, put_flash(socket, :error, "Could not play that: #{inspect(reason)}")}
    end
  end

  # Cinder gives the query that it read, with the sort and the filters of the person on
  # it, and a page keeps that in `:list_query`. A page that holds none, such as the
  # branches of a source, queues the one row that a person pressed.
  defp queue_ids(socket, pressed) do
    case socket.assigns[:list_query] do
      nil ->
        List.wrap(pressed)

      query ->
        ids =
          query
          |> Ash.Query.filter(kind == :track)
          |> Ash.Query.limit(@queue_limit)
          |> Ash.read!()
          |> Enum.map(& &1.id)

        cond do
          # The head of a collection pressed play, and it is no row of the list.
          is_nil(pressed) -> ids
          pressed in ids -> ids
          true -> [pressed]
        end
    end
  end

  # A device in standby draws no list, so this holds the mark and reads nothing. See the
  # module documentation.
  defp info(%Event.Source.Changed{}, %{assigns: %{standby?: true}} = socket) do
    {:halt, Phoenix.Component.assign(socket, :stale?, true)}
  end

  defp info(%Event.Source.Changed{}, socket), do: {:halt, read_again(socket)}

  # `MyHiFiWeb.Shell` holds this event as well, and it passes it on, so the value of
  # `standby?` above is the new one by the time that this runs.
  defp info(%Events.Standby{entered?: false}, %{assigns: %{stale?: true}} = socket) do
    {:cont, socket |> Phoenix.Component.assign(:stale?, false) |> read_again()}
  end

  defp info(%Events.Started{track: %{id: id}}, socket) do
    {:halt, Phoenix.Component.assign(socket, :playing, %{item_id: id, status: :playing})}
  end

  defp info(%Events.Paused{}, socket), do: {:halt, put_status(socket, :paused)}
  defp info(%Events.Buffering{}, socket), do: {:halt, put_status(socket, :buffering)}

  defp info(%event{}, socket) when event in [Events.Stopped, Events.Failed] do
    {:halt, Phoenix.Component.assign(socket, :playing, nil)}
  end

  defp info(_message, socket), do: {:cont, socket}

  # A page that draws no collection holds no identifier, and `MyHiFiWeb.BrowseLive`
  # draws none while it says that this firmware holds no source.
  defp read_again(socket) do
    case socket.assigns[:collection_id] do
      nil -> socket
      collection_id -> Cinder.Refresh.refresh_table(socket, collection_id)
    end
  end

  defp mark(%{favourite?: true} = item), do: Playback.clear_favourite(item)
  defp mark(item), do: Playback.set_favourite(item)

  defp playing(%{playing?: true, item: %{id: id}}), do: %{item_id: id, status: :playing}
  defp playing(%{paused?: true, item: %{id: id}}), do: %{item_id: id, status: :paused}
  defp playing(_state), do: nil

  defp put_status(%{assigns: %{playing: nil}} = socket, _status), do: socket

  defp put_status(socket, status) do
    Phoenix.Component.assign(socket, :playing, %{socket.assigns.playing | status: status})
  end

  # One item of the catalogue is one row of a list, so the identifier is the whole
  # answer. Two sources cannot hold one item.
  defp status_of(%{item_id: id, status: status}, _source, %{id: id}), do: status
  defp status_of(_playing, _source, _row), do: nil

  defp status_text(:paused), do: "Paused"
  defp status_text(:buffering), do: "Buffering"
  defp status_text(_status), do: "Playing"
end
