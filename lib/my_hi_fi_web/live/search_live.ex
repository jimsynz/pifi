defmodule MyHiFiWeb.SearchLive do
  @moduledoc """
  Find an item by its name.

  `MyHiFiWeb.BrowseLive` walks a tree, and this page holds no tree at all. It is one
  collection of the items that `c:MyHiFi.Source.search/1` names, and Cinder matches the
  text against them.

  ## The text is in the address

  `/search/podcasts?search=history` is what a person reads, and Cinder writes that
  parameter itself. A reload and a bookmark therefore both work, in the way that they do
  on the browse page.

  ## The control that chooses a kind

  A source that holds more than one kind of item gets a control to choose between them,
  and `c:MyHiFi.Source.kinds/0` gives the word for each one. Podcasts holds shows and
  episodes, so a person narrows the list to one or the other. Internet radio holds
  stations and nothing else, and it therefore gets no such control.

  ## The matching is ours and not the one that Cinder gives

  `MyHiFiWeb.ItemList.search_title/3` holds the expression, and it says why. The browse
  page reads the same one.
  """

  use MyHiFiWeb, :live_view

  alias MyHiFi.Source
  alias MyHiFiWeb.ItemList

  import MyHiFiWeb.ItemList, only: [row: 1]

  on_mount(MyHiFiWeb.ItemList)

  @collection "search"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Search")
     |> assign(:collection_id, @collection)
     |> assign(:list_query, nil)
     |> assign(:url_state, nil)}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"source" => slug} = params, uri, socket) do
    with {:ok, module} <- Source.from_slug(slug),
         true <- Source.enabled?(module),
         true <- :search in module.capabilities() do
      :ok = Source.choose(module)

      {:noreply,
       socket
       |> at(module, params["search"] || "")
       |> then(&Cinder.UrlSync.handle_params(params, uri, &1))}
    else
      _other -> {:noreply, push_navigate(socket, to: ~p"/browse/#{slug}")}
    end
  end

  # A source may reach a service to answer, so the query is built one time for each text
  # and not one time for each press of a control. See `c:MyHiFi.Source.search/1`.
  defp at(socket, module, text) do
    if socket.assigns[:source] == module and socket.assigns[:text] == text do
      socket
    else
      socket
      |> assign(:source, module)
      |> assign(:current_source, Source.slug(module))
      |> assign(:text, text)
      |> assign(:page_title, "Search #{module.title()}")
      |> assign(:kinds, options_of(module))
      |> assign(:query, module.search(text))
    end
  end

  # A source names what a person calls its items, and the control to choose between them
  # is worth drawing only for a source that holds more than one kind. Internet radio
  # holds stations and nothing else, so it gets no control at all.
  defp options_of(module) do
    Enum.map(module.kinds(), fn {kind, name} -> {name, to_string(kind)} end)
  end

  # A container never plays, so it opens. This page holds no tree, and the browse page
  # addresses a container by its identifier, with no branch above it. See
  # `MyHiFiWeb.BrowseLive`.
  @impl Phoenix.LiveView
  def handle_event("open", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/browse/#{socket.assigns.current_source}/#{[id]}")}
  end

  # Cinder gives the query that it read, with the sort and the filters of the person on
  # it. `MyHiFiWeb.ItemList` reads it when a person presses play, so the list that they
  # see goes in the queue.
  @impl Phoenix.LiveView
  def handle_info({:list_query, %{query: query}}, socket) do
    {:noreply, assign(socket, :list_query, query)}
  end

  # This is the clause that `use Cinder.UrlSync` writes. This page writes it out, for
  # the reason that `MyHiFiWeb.BrowseLive` gives.
  def handle_info({:table_state_change, _id, state}, socket) do
    {:noreply,
     Cinder.UrlSync.update_url(socket, state, get_in(socket.assigns, [:url_state, :uri]))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div id="search">
      <nav aria-label="Where you are" class="mb-4 flex items-center gap-1 text-sm">
        <.link
          navigate={~p"/browse/#{@current_source}"}
          class="rounded px-1 py-0.5 text-ink-dim hover:text-accent"
        >
          {@source.title()}
        </.link>
        <.icon name="hero-chevron-right-micro" class="size-3 text-ink-faint" />
        <span class="rounded px-1 py-0.5 text-ink">Search</span>
      </nav>

      <Cinder.collection
        id={@collection_id}
        query={@query}
        layout={:list}
        url_state={@url_state}
        page_size={25}
        empty_message="Nothing matches that."
        loading_message="Reading…"
        filters_label="Find"
        sort_label="Sort"
        show_filters={true}
        search={
          [label: "Name", placeholder: "Search #{@source.title()}…", fn: &ItemList.search_title/3]
        }
        query_opts={[load: [:child_count, :artwork, :audio_held?]]}
        on_query_change={:list_query}
      >
        <:col field="sorted_title" label="Title" search sort />

        <:col
          :if={length(@kinds) > 1}
          field="kind"
          label="Kind"
          filter={:select}
          filter_options={[options: @kinds, prompt: "Everything"]}
        />

        <:item :let={item}>
          <.row row={item} playing={@playing} source={@source} reading={@reading} />
        </:item>
      </Cinder.collection>
    </div>
    """
  end
end
