defmodule MyHiFiWeb.BrowseLive do
  @moduledoc """
  Find something to play.

  The address names the source, and the top row of the faceplate holds one control
  for each source. The page then moves through the tree of that source. It holds
  no knowledge of any particular service: it reads `title`, `artwork` and
  `favourite?` from each entry, and it gives the `ref` back untouched. See
  `MyHiFi.Source`.

  The page keeps the `ref` of each entry in its own state, and each control names
  an entry by its place in the list. A `ref` is a term of the source, so a page
  that put one in an address would have to turn text back into a term, and no
  page reads a term from a person. The name of a source is not a `ref`, and
  `MyHiFi.Source.from_slug/1` compares it with the sources that this firmware
  holds.
  """

  use MyHiFiWeb, :live_view

  alias MyHiFi.Event
  alias MyHiFi.Event.Player, as: Events
  alias MyHiFi.Playback
  alias MyHiFi.Source

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Event.subscribe(:player)

    {:ok,
     socket
     |> assign(:page_title, "Browse")
     |> assign(:current, current(Playback.state!()))}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"source" => slug}, _uri, socket) do
    with {:ok, module} <- Source.from_slug(slug),
         true <- Source.enabled?(module) do
      {:noreply, socket |> start_at(module) |> load()}
    else
      _other -> {:noreply, first_source(socket)}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _uri, socket), do: {:noreply, first_source(socket)}

  @impl Phoenix.LiveView
  def handle_info(%Events.Started{source: source, track: %{ref: ref}}, socket) do
    {:noreply, assign(socket, :current, %{source: source, ref: ref, status: :playing})}
  end

  # A pause keeps the track selected, so the marker stays and it names the pause. A
  # buffer holds the same place, and it makes no sound yet. Neither event names a
  # track, so each one changes the state of the entry that the page already marks.
  @impl Phoenix.LiveView
  def handle_info(%Events.Paused{}, socket), do: {:noreply, put_status(socket, :paused)}

  @impl Phoenix.LiveView
  def handle_info(%Events.Buffering{}, socket), do: {:noreply, put_status(socket, :buffering)}

  @impl Phoenix.LiveView
  def handle_info(%event{}, socket) when event in [Events.Stopped, Events.Failed] do
    {:noreply, assign(socket, :current, nil)}
  end

  # The page ignores every other event of the player. A progress event arrives
  # once a second, and the marker of the list does not change with it.
  @impl Phoenix.LiveView
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("clear_search", _params, socket) do
    {:noreply, socket |> assign(:query, nil) |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("crumb", %{"index" => index}, socket) do
    {:noreply,
     socket
     |> assign(:path, Enum.take(socket.assigns.path, to_index(index) + 1))
     |> assign(:query, nil)
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("favourite", %{"index" => index}, socket) do
    case entry_at(socket, index) do
      nil -> {:noreply, socket}
      entry -> {:noreply, mark(socket, to_index(index), entry)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("more", _params, socket) do
    {:noreply, load_more(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("open", %{"index" => index}, socket) do
    case entry_at(socket, index) do
      {:container, container} ->
        {:noreply,
         socket
         |> assign(:path, socket.assigns.path ++ [container])
         |> assign(:query, nil)
         |> load()}

      _other ->
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("play", %{"index" => index}, socket) do
    case entry_at(socket, index) do
      {:track, track} -> {:noreply, play(socket, track)}
      _other -> {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    case String.trim(query) do
      "" -> {:noreply, socket |> assign(:query, nil) |> load()}
      query -> {:noreply, socket |> assign(:query, query) |> load()}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div id="browse">
      <p :if={is_nil(@source)} id="no-source" class="text-ink-dim">
        This firmware holds no source.
      </p>

      <div :if={@source}>
        <div class="mb-4 flex flex-wrap items-center gap-3">
          <nav id="crumbs" aria-label="Where you are" class="flex flex-wrap items-center gap-1 text-sm">
            <span :for={{crumb, index} <- Enum.with_index(@path)} class="flex items-center gap-1">
              <.icon
                :if={index > 0}
                name="hero-chevron-right-micro"
                class="size-3 text-ink-faint"
              />
              <button
                type="button"
                id={"crumb-#{index}"}
                phx-click="crumb"
                phx-value-index={index}
                disabled={index == length(@path) - 1 and is_nil(@query)}
                class={[
                  "rounded px-1 py-0.5",
                  if(index == length(@path) - 1 and is_nil(@query),
                    do: "text-ink",
                    else: "text-ink-dim hover:text-accent"
                  )
                ]}
              >
                {crumb.title}
              </button>
            </span>

            <span :if={@query} class="flex items-center gap-1 text-ink">
              <.icon name="hero-chevron-right-micro" class="size-3 text-ink-faint" />
              <span>Search for {@query}</span>
            </span>
          </nav>

          <.form
            :if={@search?}
            for={@search_form}
            id="search-form"
            phx-submit="search"
            class="w-full sm:ml-auto sm:w-auto"
          >
            <div class="flex items-center gap-2">
              <.input
                field={@search_form[:query]}
                type="search"
                placeholder="Search"
                class="grow sm:w-56"
              />
              <button
                type="submit"
                id="do-search"
                aria-label="Search"
                class="control flex size-10 shrink-0 items-center justify-center rounded-lg"
              >
                <.icon name="hero-magnifying-glass" class="size-4" />
              </button>
              <button
                :if={@query}
                type="button"
                id="clear-search"
                phx-click="clear_search"
                aria-label="Clear the search"
                class="control flex size-10 shrink-0 items-center justify-center rounded-lg"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
          </.form>
        </div>

        <p :if={@entries == []} id="empty" class="glass rounded-xl px-4 py-8 text-center text-ink-faint">
          Nothing here.
        </p>

        <ul :if={@entries != []} id="entries" class="glass overflow-hidden rounded-xl">
          <li
            :for={{entry, index} <- Enum.with_index(@entries)}
            id={"entry-#{index}"}
            class={[
              "relative flex items-center gap-2 border-b border-edge px-2 last:border-0",
              current_entry?(assigns, entry) && "bg-accent/12"
            ]}
          >
            <%!-- The bar down the left edge marks the row that plays, and the eye finds
            it in a long list without a read of any title. --%>
            <span
              :if={current_entry?(assigns, entry)}
              aria-hidden="true"
              class="led absolute inset-y-0 left-0 w-[3px]"
            />
            <%= case entry do %>
              <% {:container, container} -> %>
                <button
                  type="button"
                  id={"open-#{index}"}
                  phx-click="open"
                  phx-value-index={index}
                  class="group flex min-w-0 grow items-center gap-3 py-3 text-left"
                >
                  <.icon name="hero-folder" class="size-4 shrink-0 text-ink-faint" />
                  <%!-- `min-w-0` is what makes `truncate` work. A flex item keeps its
                  content width without it, so a long title pushed the chevron and the
                  star of a podcast show off the row. --%>
                  <span class="min-w-0 grow truncate text-ink group-hover:text-accent">
                    {container.title}
                  </span>
                  <.icon
                    name="hero-chevron-right-mini"
                    class="size-4 shrink-0 text-ink-faint group-hover:text-accent"
                  />
                </button>
              <% {:track, track} -> %>
                <.track track={track} index={index} status={current_status(assigns, track)} />
            <% end %>
            <.favourite entry={entry} index={index} />
          </li>
        </ul>

        <button
          :if={@cursor}
          type="button"
          id="more"
          phx-click="more"
          class="control mt-4 w-full rounded-xl py-3 text-sm"
        >
          Show more
        </button>
      </div>
    </div>
    """
  end

  # The row of a track. `status` is `nil` for each track that the player does not
  # hold, and the marker of the current one holds three parts: a level meter in the
  # place of the play control, the state in words, and the title in the accent
  # colour. A person then knows the row from a look, and a person who reads the
  # screen with a reader gets `aria-current` and the same words.
  attr :track, :any, required: true
  attr :index, :integer, required: true
  attr :status, :atom, required: true

  defp track(assigns) do
    ~H"""
    <button
      type="button"
      id={"play-#{@index}"}
      phx-click="play"
      phx-value-index={@index}
      aria-current={@status && "true"}
      class="group flex min-w-0 grow items-center gap-3 py-3 text-left"
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
        <span
          :if={@status}
          class="block text-[0.65rem] uppercase tracking-[0.18em] text-accent"
        >
          {status_text(@status)}
        </span>
        <span class={[
          "block truncate",
          if(@status, do: "font-medium text-accent", else: "text-ink group-hover:text-accent")
        ]}>
          {@track.title}
        </span>
        <span :if={@track.subtitle} class="block truncate text-xs text-ink-faint">
          {@track.subtitle}
        </span>
      </span>
    </button>
    """
  end

  # One control for a track and for a container. A station is a track and a podcast
  # show is a container, and each one carries `favourite?`, so this needs no
  # knowledge of which source it draws. A `nil` mark draws nothing.
  attr :entry, :any, required: true
  attr :index, :integer, required: true

  defp favourite(assigns) do
    assigns = assign(assigns, :marked, elem(assigns.entry, 1).favourite?)

    ~H"""
    <button
      :if={is_boolean(@marked)}
      type="button"
      id={"favourite-#{@index}"}
      phx-click="favourite"
      phx-value-index={@index}
      aria-pressed={to_string(@marked == true)}
      aria-label="Favourite"
      class={[
        "flex size-9 shrink-0 items-center justify-center rounded-full",
        if(@marked, do: "text-accent", else: "text-ink-faint hover:text-ink")
      ]}
    >
      <.icon name={if @marked, do: "hero-star-solid", else: "hero-star"} class="size-5" />
    </button>
    """
  end

  # The player holds the track, and the track holds its `ref`, so the list needs no
  # knowledge of the source to find the entry that plays. A pause holds the track as
  # well, and a boot restores a paused track, so the marker must draw for that state
  # too. See section 9 of the specification.
  defp current(%{playing?: true, source: source, track: %{ref: ref}}) do
    %{source: source, ref: ref, status: :playing}
  end

  defp current(%{paused?: true, source: source, track: %{ref: ref}}) do
    %{source: source, ref: ref, status: :paused}
  end

  defp current(_state), do: nil

  defp put_status(%{assigns: %{current: nil}} = socket, _status), do: socket

  defp put_status(socket, status) do
    assign(socket, :current, %{socket.assigns.current | status: status})
  end

  defp current_status(%{current: %{source: source, ref: ref, status: status}, source: source}, %{
         ref: ref
       }) do
    status
  end

  defp current_status(_assigns, _track), do: nil

  defp current_entry?(assigns, {:track, track}), do: not is_nil(current_status(assigns, track))
  defp current_entry?(_assigns, _entry), do: false

  defp status_text(:paused), do: "Paused"
  defp status_text(:buffering), do: "Buffering"
  defp status_text(_status), do: "Playing"

  defp first_source(socket) do
    case Source.enabled() do
      [module | _rest] -> push_navigate(socket, to: ~p"/browse/#{Source.slug(module)}")
      [] -> start_at(socket, nil)
    end
  end

  defp start_at(socket, nil) do
    socket
    |> assign(:source, nil)
    |> assign(:current_source, nil)
    |> assign(:path, [])
    |> assign(:entries, [])
    |> assign(:cursor, nil)
    |> assign(:query, nil)
    |> assign(:search?, false)
    |> assign(:search_form, to_form(%{"query" => ""}, as: :search))
  end

  defp start_at(socket, module) do
    socket
    |> assign(:source, module)
    |> assign(:current_source, Source.slug(module))
    |> assign(:page_title, module.title())
    |> assign(:path, [%{ref: module.root(), title: module.title()}])
    |> assign(:entries, [])
    |> assign(:cursor, nil)
    |> assign(:query, nil)
    |> assign(:search?, :search in module.capabilities())
    |> assign(:search_form, to_form(%{"query" => ""}, as: :search))
  end

  defp load(socket) do
    case read(socket, nil) do
      {:ok, page} ->
        socket
        |> assign(:entries, page.entries)
        |> assign(:cursor, page.cursor)
        |> assign(:search_form, to_form(%{"query" => socket.assigns.query || ""}, as: :search))

      {:error, reason} ->
        socket
        |> assign(:entries, [])
        |> assign(:cursor, nil)
        |> put_flash(:error, "This source gave an error: #{inspect(reason)}")
    end
  end

  defp load_more(%{assigns: %{cursor: nil}} = socket), do: socket

  defp load_more(socket) do
    case read(socket, socket.assigns.cursor) do
      {:ok, page} ->
        socket
        |> assign(:entries, socket.assigns.entries ++ page.entries)
        |> assign(:cursor, page.cursor)

      {:error, reason} ->
        put_flash(socket, :error, "This source gave an error: #{inspect(reason)}")
    end
  end

  defp read(%{assigns: %{source: source, query: query}} = socket, cursor) when is_binary(query) do
    source.search(query, options(socket, cursor))
  end

  defp read(%{assigns: %{source: source, path: path}} = socket, cursor) do
    source.browse(List.last(path).ref, options(socket, cursor))
  end

  defp options(_socket, nil), do: []
  defp options(_socket, cursor), do: [cursor: cursor]

  defp play(socket, track) do
    case Playback.play(socket.assigns.source, track.ref) do
      :ok ->
        socket
        |> assign(:current, %{
          source: socket.assigns.source,
          ref: track.ref,
          status: :buffering
        })
        |> put_flash(:info, "Playing #{track.title}.")

      {:error, reason} ->
        put_flash(socket, :error, "Could not play that: #{inspect(reason)}")
    end
  end

  defp mark(socket, _index, {_kind, %{favourite?: nil}}), do: socket

  defp mark(socket, index, {_kind, entry} = whole) do
    case socket.assigns.source.favourite(entry.ref, not entry.favourite?) do
      :ok -> assign(socket, :entries, refresh(socket, index, whole))
      {:error, reason} -> put_flash(socket, :error, "Could not do that: #{inspect(reason)}")
    end
  end

  # The source holds the mark, so the page reads a track again instead of writing
  # what it thinks the new state is.
  defp refresh(socket, index, {:track, track}) do
    case socket.assigns.source.track(track.ref) do
      {:ok, track} -> List.replace_at(socket.assigns.entries, index, {:track, track})
      {:error, _reason} -> socket.assigns.entries
    end
  end

  # A container has no such read. The behaviour names `track/1` and no
  # `container/1`, and one page refreshing one star does not earn a callback that
  # every source must then implement. `favourite/2` gave `:ok`, so the new state is
  # the state that this page asked for. Reading the list again is the other answer,
  # and for a search of a service that would be a request to it for each star.
  defp refresh(socket, index, {:container, container}) do
    container = %{container | favourite?: not container.favourite?}

    List.replace_at(socket.assigns.entries, index, {:container, container})
  end

  defp entry_at(socket, index), do: Enum.at(socket.assigns.entries, to_index(index))

  defp to_index(index) when is_integer(index), do: index
  defp to_index(index) when is_binary(index), do: String.to_integer(index)
end
