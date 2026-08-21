defmodule MyHiFiWeb.BrowseLive do
  @moduledoc """
  Find something to play.

  The page shows the source list, and then it moves through the tree of one
  source. It holds no knowledge of any particular service: it reads `title`,
  `artwork` and `favourite?` from each entry, and it gives the `ref` back
  untouched. See `MyHiFi.Source`.

  The page keeps the `ref` of each entry in its own state, and each control names
  an entry by its place in the list. A `ref` is a term of the source, so a page
  that put one in an address would have to turn text back into a term, and no
  page reads a term from a person.
  """

  use MyHiFiWeb, :live_view

  alias MyHiFi.Source

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    sources = Enum.map(Source.all(), &%{module: &1, title: &1.title()})

    {:ok,
     socket
     |> assign(:page_title, "Browse")
     |> assign(:sources, sources)
     |> show_sources()}
  end

  @impl Phoenix.LiveView
  def handle_event("sources", _params, socket) do
    {:noreply, show_sources(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("choose_source", %{"index" => index}, socket) do
    %{module: module, title: title} = Enum.at(socket.assigns.sources, to_index(index))

    {:noreply,
     socket
     |> assign(:source, module)
     |> assign(:path, [%{ref: module.root(), title: title}])
     |> assign(:search?, true)
     |> assign(:query, nil)
     |> load()}
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
  def handle_event("crumb", %{"index" => index}, socket) do
    {:noreply,
     socket
     |> assign(:path, Enum.take(socket.assigns.path, to_index(index) + 1))
     |> assign(:query, nil)
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    case String.trim(query) do
      "" -> {:noreply, socket |> assign(:query, nil) |> load()}
      query -> {:noreply, socket |> assign(:query, query) |> load()}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("clear_search", _params, socket) do
    {:noreply, socket |> assign(:query, nil) |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("more", _params, socket) do
    {:noreply, load_more(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("play", %{"index" => index}, socket) do
    case entry_at(socket, index) do
      {:track, track} -> {:noreply, play(socket, track)}
      _other -> {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("favourite", %{"index" => index}, socket) do
    case entry_at(socket, index) do
      {:track, track} -> {:noreply, mark(socket, to_index(index), track)}
      _other -> {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div id="browse" class="mx-auto max-w-xl p-6">
      <div class="flex items-baseline justify-between mb-6">
        <h1 class="text-2xl font-semibold">Browse</h1>
        <.link navigate={~p"/"} class="text-sm underline">Now playing</.link>
      </div>

      <%= if @source do %>
        <nav id="crumbs" class="text-sm text-zinc-600 mb-4">
          <button type="button" phx-click="sources" class="underline">Sources</button>
          <span :for={{crumb, index} <- Enum.with_index(@path)}>
            <span class="text-zinc-400">/</span>
            <button
              type="button"
              id={"crumb-#{index}"}
              phx-click="crumb"
              phx-value-index={index}
              class="underline"
            >
              {crumb.title}
            </button>
          </span>
          <span :if={@query}>
            <span class="text-zinc-400">/</span>
            <span>Search for {@query}</span>
          </span>
        </nav>

        <.form :if={@search?} for={@search_form} id="search-form" phx-submit="search" class="mb-4">
          <div class="flex gap-2">
            <.input field={@search_form[:query]} type="search" placeholder="Search" />
            <button type="submit" id="do-search" class="rounded px-4 py-2 bg-zinc-800 text-white">
              Search
            </button>
            <button
              :if={@query}
              type="button"
              id="clear-search"
              phx-click="clear_search"
              class="rounded px-4 py-2 border border-zinc-400"
            >
              Clear
            </button>
          </div>
        </.form>

        <p :if={@entries == []} id="empty" class="text-zinc-500">Nothing here.</p>

        <ul id="entries" class="divide-y divide-zinc-200">
          <li
            :for={{entry, index} <- Enum.with_index(@entries)}
            id={"entry-#{index}"}
            class="py-2 flex items-center gap-3"
          >
            <%= case entry do %>
              <% {:container, container} -> %>
                <button
                  type="button"
                  id={"open-#{index}"}
                  phx-click="open"
                  phx-value-index={index}
                  class="grow text-left"
                >
                  {container.title}
                </button>
                <span class="text-zinc-400">&rsaquo;</span>
              <% {:track, track} -> %>
                <button
                  type="button"
                  id={"play-#{index}"}
                  phx-click="play"
                  phx-value-index={index}
                  class="grow text-left"
                >
                  <span class="block">{track.title}</span>
                  <span :if={track.subtitle} class="block text-sm text-zinc-500">
                    {track.subtitle}
                  </span>
                </button>
                <button
                  :if={is_boolean(track.favourite?)}
                  type="button"
                  id={"favourite-#{index}"}
                  phx-click="favourite"
                  phx-value-index={index}
                  aria-pressed={to_string(track.favourite? == true)}
                  class="px-2 text-xl"
                >
                  {if track.favourite?, do: "★", else: "☆"}
                </button>
            <% end %>
          </li>
        </ul>

        <button
          :if={@cursor}
          type="button"
          id="more"
          phx-click="more"
          class="mt-4 rounded px-4 py-2 border border-zinc-400"
        >
          Show more
        </button>
      <% else %>
        <ul id="sources" class="divide-y divide-zinc-200">
          <li :for={{source, index} <- Enum.with_index(@sources)} class="py-2">
            <button
              type="button"
              id={"source-#{index}"}
              phx-click="choose_source"
              phx-value-index={index}
              class="w-full text-left"
            >
              {source.title}
            </button>
          </li>
        </ul>
      <% end %>
    </div>
    """
  end

  defp show_sources(socket) do
    socket
    |> assign(:source, nil)
    |> assign(:path, [])
    |> assign(:entries, [])
    |> assign(:cursor, nil)
    |> assign(:query, nil)
    |> assign(:search?, false)
    |> assign(:search_form, to_form(%{"query" => ""}, as: :search))
  end

  defp load(socket) do
    case read(socket, nil) do
      {:ok, page} ->
        socket
        |> assign(:entries, page.entries)
        |> assign(:cursor, page.cursor)
        |> assign(:search_form, to_form(%{"query" => socket.assigns.query || ""}, as: :search))

      # A source without search hides the field. The behaviour gives no way to ask
      # in advance, so the page asks once and remembers the answer.
      {:error, :not_supported} ->
        socket
        |> assign(:search?, false)
        |> assign(:query, nil)
        |> put_flash(:error, "This source has no search.")
        |> load()

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
    case MyHiFi.Player.play(socket.assigns.source, track.ref) do
      :ok -> put_flash(socket, :info, "Playing #{track.title}.")
      {:error, reason} -> put_flash(socket, :error, "Could not play that: #{inspect(reason)}")
    end
  end

  defp mark(socket, index, track) do
    case socket.assigns.source.favourite(track.ref, not track.favourite?) do
      :ok -> assign(socket, :entries, refresh(socket, index, track))
      {:error, reason} -> put_flash(socket, :error, "Could not do that: #{inspect(reason)}")
    end
  end

  # The source holds the mark, so the page reads the entry again instead of
  # writing what it thinks the new state is.
  defp refresh(socket, index, track) do
    case socket.assigns.source.track(track.ref) do
      {:ok, track} -> List.replace_at(socket.assigns.entries, index, {:track, track})
      {:error, _reason} -> socket.assigns.entries
    end
  end

  defp entry_at(socket, index), do: Enum.at(socket.assigns.entries, to_index(index))

  defp to_index(index) when is_integer(index), do: index
  defp to_index(index) when is_binary(index), do: String.to_integer(index)
end
