defmodule PiFiWeb.BrowseLive do
  @moduledoc """
  Find something to play.

  The address names the source, and the top row of the faceplate draws one control for
  each source. `PiFi.Source.roots/0` gives the branches of that source, and
  everything below them is generic: this page needs no knowledge of internet radio and
  none of podcasts.

  ## Two rules make the whole tree

  A row of `PiFi.Playback.Facet` opens into the items that link to it. An item of the
  kind `:container` opens into the items whose `parent_id` names it. A source takes no
  part in either one, which is what one catalogue is for.

  ## What Cinder owns, and what this page owns

  `Cinder` runs the query. It owns the loading state, the sort, the filters and the
  page controls, so this page owns none of that: no cursor, no page of entries, and no
  read of a list inside `handle_event`. A slow read draws a loading state, which the
  page before this one did not.

  This page owns the breadcrumbs and the marker of the track that plays, because
  neither one belongs to a list.

  ## The address says where a person is

  `/browse/internet-radio/countries/NZ` is the stations of New Zealand, and
  `/browse/podcasts/subscriptions/<id>` is the episodes of one show. One segment names
  each level, and `handle_params/3` builds the path again from them, so a reload, a
  bookmark and the back control of a browser all work.

  A segment is what the level above it needs to find the row: the name of a branch at
  the top, the value of a facet under one of those, and the identifier of an item under
  a container. The rules of the tree are what make this possible, because the page can
  walk the same two steps that a person did.

  The sort, the filters and the page go in the query, and `Cinder.UrlSync` writes them:
  `/browse/internet-radio/countries/NZ?sort=-title&title=rock`. Each level is a
  collection of its own, so a sort belongs to the list that a person set it on.

  ## The letter bar

  `letter` is this page and not Cinder, and `?letter=G` carries it. A press narrows the
  list to the titles that begin with that letter. See `letters/1` for why it narrows the
  list and does not move to a page of it, and why the bar draws every letter.
  """

  use PiFiWeb, :live_view

  require Ash.Query

  alias PiFi.Artwork
  alias PiFi.Playback
  alias PiFi.Playback.Facet
  alias PiFi.Playback.Item
  alias PiFi.Source
  alias PiFiWeb.ItemList

  import PiFiWeb.ItemList,
    only: [
      card: 1,
      controls_cell: 1,
      count: 1,
      cover: 1,
      favourite: 1,
      place_cell: 1,
      play_cell: 1,
      playlist_sheet: 1,
      title_cell: 1
    ]

  on_mount(PiFiWeb.ItemList)

  @collection "browse"

  # The buttons of the letter bar. `#` is every title that begins with something that is
  # not a letter of the alphabet: a digit, a mark, or a letter of another writing system.
  @letters Enum.map(?A..?Z, &<<&1>>) ++ ["#"]

  # What `Cinder.UrlSync` writes to say which page of a list a person is on. A press of
  # a letter takes all three away. See `letter_address/2`.
  @cursor_params ~w[after before page]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Browse")
     |> assign(:finding?, false)
     |> assign(:letter, nil)
     |> assign(:list_layout, :table)
     |> assign(:root_counts, %{})
     |> assign(:opened, nil)
     |> assign(:tracks_only?, false)
     |> assign(:list_query, nil)
     |> assign(:collection_id, nil)
     |> assign(:url_state, nil)}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"source" => slug} = params, uri, socket) do
    with {:ok, module} <- Source.from_slug(slug),
         true <- Source.enabled?(module) do
      :ok = Source.choose(module)

      # `Cinder.UrlSync.handle_params/3` gives the socket, and it writes `:url_state`
      # on it. Do not put what it returns into an assign.
      {:noreply,
       socket
       |> assign(:finding?, params["find"] == "1")
       |> assign(:letter, chosen_letter(params["letter"]))
       |> assign(:list_layout, chosen_layout(params["view"]))
       |> at(module, params["path"] || [])
       |> then(&Cinder.UrlSync.handle_params(params, uri, &1))}
    else
      _other -> {:noreply, chosen_source(socket)}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _uri, socket), do: {:noreply, chosen_source(socket)}

  @impl Phoenix.LiveView
  def handle_event("layout", %{"view" => view}, socket) do
    {:noreply, push_patch(socket, to: layout_address(socket, chosen_layout(view)))}
  end

  @impl Phoenix.LiveView
  def handle_event("open_root", %{"index" => index}, socket) do
    {name, _listing} = Enum.at(socket.assigns.roots, to_index(index))

    {:noreply, go(socket, socket.assigns.segments ++ [slug(name)])}
  end

  # A facet opens into the items that hold it, and a container opens into what it
  # names. Neither rule needs the source.
  def handle_event("open", %{"id" => id}, socket) do
    case here(socket.assigns) do
      %{kind: :facet} -> {:noreply, open_facet(socket, id)}
      %{kind: :item} -> {:noreply, open_item(socket, id)}
      nil -> {:noreply, socket}
    end
  end

  # **A person reaches an album from the list of albums, from the favourites and from a
  # search, and no crumb of those paths names the artist.** The head of the collection
  # therefore draws the container above this one, and this opens it.
  #
  # The address carries that identifier and nothing above it, because a container opens
  # by its identifier under no branch. See `step/3`.
  def handle_event("open_parent", %{"id" => id}, socket) do
    {:noreply, go(socket, [id])}
  end

  # The controls take the room of three rows of the list, and a person wants them for a
  # long list alone. They therefore start out of sight, and this control brings them.
  def handle_event("find", _params, socket) do
    socket = assign(socket, :finding?, !socket.assigns.finding?)

    {:noreply, go(socket, socket.assigns.segments)}
  end

  # **A press of the letter that is on takes the narrowing away**, because the bar keeps
  # no control for "every letter" and a person who pressed G must be able to go back.
  def handle_event("letter", %{"letter" => letter}, socket) do
    chosen = if socket.assigns.letter == letter, do: nil, else: chosen_letter(letter)

    {:noreply, push_patch(socket, to: letter_address(socket, chosen))}
  end

  # A person who will not wait for the schedule asks for the read now. The source
  # publishes `PiFi.Event.Source.Changed` when it finishes, and the list then reads
  # itself again.
  def handle_event("refresh", _params, socket) do
    case Source.refresh(socket.assigns.source, opened_item(socket.assigns)) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Refreshing that list.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't refresh that list.")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("crumb", %{"index" => index}, socket) do
    {:noreply, go(socket, Enum.take(socket.assigns.segments, to_index(index)))}
  end

  # A person types a name, and the tree is not what finds it. See `PiFiWeb.SearchLive`.
  def handle_event("search", %{"text" => text}, socket) do
    case String.trim(text) do
      "" ->
        {:noreply, socket}

      trimmed ->
        {:noreply,
         push_navigate(socket,
           to: ~p"/search/#{socket.assigns.current_source}?#{%{search: trimmed}}"
         )}
    end
  end

  # Cinder gives the query that it read, with the sort and the filters of the person on
  # it. `PiFiWeb.ItemList` reads it when a person presses play, so the list that they
  # see goes in the queue.
  @impl Phoenix.LiveView
  def handle_info({:list_query, %{query: query}}, socket) do
    {:noreply, assign(socket, :list_query, query)}
  end

  # This is the clause that `use Cinder.UrlSync` writes. This page writes it out,
  # because the macro puts it where the `use` stands and the compiler then reports that
  # the clauses of `handle_info/2` are not together.
  def handle_info({:table_state_change, _id, state}, socket) do
    {:noreply,
     Cinder.UrlSync.update_url(socket, state, get_in(socket.assigns, [:url_state, :uri]))}
  end

  # A progress event arrives once a second, and no list changes with it.
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns =
      assigns
      |> assign(:here, here(assigns))
      |> assign(:refreshable?, refreshable?(assigns))

    ~H"""
    <div id="browse">
      <p :if={is_nil(@source)} id="no-source" class="text-ink-dim">
        No sources are set up yet.
      </p>

      <div :if={@source}>
        <.crumbs
          path={@path}
          source={@source}
          finding?={@finding?}
          collection?={not is_nil(@here)}
          refreshable?={@refreshable?}
        />

        <.playlist_sheet adding={@adding} playlists={@playlists} />

        <.finder :if={is_nil(@here) and @searchable?} source={@source} />

        <.receive_only :if={is_nil(@here) and not is_list(@roots)} source={@source} />

        <.roots :if={is_nil(@here) and is_list(@roots)} roots={@roots} counts={@root_counts} />

        <.collection_header :if={@opened} item={@opened} playable?={@tracks_only?} />

        <.letters :if={@finding? and item_list?(@here)} letter={@letter} />

        <.layout_choice :if={@here} layout={@list_layout} />

        <Cinder.collection
          :if={@here}
          id={@collection_id}
          query={@here.query}
          layout={@list_layout}
          grid_columns={[xs: 2, sm: 3, lg: 4]}
          url_state={@url_state}
          page_size={25}
          empty_message="Nothing here."
          loading_message="Reading…"
          filters_label="Filter"
          sort_label="Sort"
          show_filters={@finding?}
          show_sort={@finding? or not is_nil(@here[:order])}
          query_opts={[load: loads(@here.kind)]}
          on_query_change={:list_query}
        >
          <:col :let={row} label="" class="w-10">
            <.play_cell row={row} kind={@here.kind} playing={@playing} source={@source} />
          </:col>

          <:col
            :let={row}
            :if={@here[:order]}
            field={@here[:order] && elem(@here[:order], 1)}
            label={@here[:order] && elem(@here[:order], 0)}
            sort
            class="w-14"
          >
            <.place_cell row={row} kind={@here.kind} number?={@here[:number?] || false} />
          </:col>

          <:col
            :let={row}
            field={field(@here.kind)}
            label={label(@path, @here)}
            sort
            filter={filter(@here.kind)}
          >
            <.title_cell row={row} kind={@here.kind} facts={@here[:facts] || []} />
          </:col>

          <:col :let={row} label="" class="w-32">
            <.controls_cell row={row} kind={@here.kind} reading={@reading} />
          </:col>

          <:item :let={row}>
            <.card
              row={row}
              kind={@here.kind}
              playing={@playing}
              source={@source}
              facts={@here[:facts] || []}
              reading={@reading}
            />
          </:item>
        </Cinder.collection>
      </div>
    </div>
    """
  end

  attr :letter, :string, default: nil

  # **A press narrows the list to the titles that begin with one letter.** A library of
  # this device keeps 4377 albums and the list reads 25 of them in a page, so a person
  # who wanted one that begins with G moved through 176 pages one press at a time.
  #
  # **Every letter draws, and the bar says nothing about what the list contains.** A count
  # for each letter reads `substr` of every row, and no index of this table serves that,
  # so a library of 68,273 rows would build a temporary tree for each draw of the page.
  # A letter that matches nothing gives "Nothing here.", and one more press takes it away.
  #
  # It draws beside the filter and the sort, and not over the list, because a list of an
  # album has 12 tracks and a bar of 27 controls above it is noise.
  defp letters(assigns) do
    assigns = assign(assigns, :letters, @letters)

    ~H"""
    <nav id="letters" aria-label="Jump to a letter" class="mb-3 flex flex-wrap gap-1">
      <button
        :for={letter <- @letters}
        type="button"
        id={letter_id(letter)}
        phx-click="letter"
        phx-value-letter={letter}
        aria-pressed={to_string(letter == @letter)}
        class={[
          "control flex size-7 shrink-0 items-center justify-center rounded-lg text-xs",
          if(letter == @letter, do: "control-on")
        ]}
      >
        {letter}
      </button>
    </nav>
    """
  end

  # A `#` is no name for a part of a page, and a selector of a test cannot read one.
  defp letter_id("#"), do: "letter-other"
  defp letter_id(letter), do: "letter-#{String.downcase(letter)}"

  # The bar draws for the items alone. See `starting_with/2`.
  defp item_list?(%{kind: :item}), do: true
  defp item_list?(_here), do: false

  attr :path, :list, required: true
  attr :source, :any, required: true
  attr :finding?, :boolean, required: true
  attr :collection?, :boolean, required: true
  attr :refreshable?, :boolean, required: true

  defp crumbs(assigns) do
    ~H"""
    <nav
      id="crumbs"
      aria-label="Breadcrumb"
      class="mb-4 flex flex-wrap items-center gap-1 text-sm"
    >
      <button
        type="button"
        id="crumb-0"
        phx-click="crumb"
        phx-value-index="0"
        disabled={@path == []}
        class={[
          "rounded px-1 py-0.5",
          "display",
          if(@path == [], do: "text-ink", else: "text-ink-dim hover:text-accent")
        ]}
      >
        {@source.title()}
      </button>

      <span :for={{crumb, index} <- Enum.with_index(@path)} class="flex items-center gap-1">
        <.icon name="ph-caret-right" class="size-3 text-ink-faint" />
        <button
          type="button"
          id={"crumb-#{index + 1}"}
          phx-click="crumb"
          phx-value-index={index + 1}
          disabled={index == length(@path) - 1}
          class={[
            "rounded px-1 py-0.5",
            if(index == length(@path) - 1,
              do: "text-ink",
              else: "text-ink-dim hover:text-accent"
            )
          ]}
        >
          {crumb.title}
        </button>
      </span>

      <span class="ml-auto flex items-center gap-1">
        <button
          :if={@refreshable?}
          type="button"
          id="refresh"
          phx-click="refresh"
          aria-label="Refresh this list"
          class="control flex size-8 shrink-0 items-center justify-center rounded-lg"
        >
          <.icon name="ph-arrows-clockwise" class="size-4" />
        </button>

        <button
          :if={@collection?}
          type="button"
          id="find"
          phx-click="find"
          aria-pressed={to_string(@finding?)}
          aria-label="Filter and sort"
          class={[
            "control flex size-8 shrink-0 items-center justify-center rounded-lg",
            if(@finding?, do: "control-on")
          ]}
        >
          <.icon name="ph-faders-horizontal" class="size-4" />
        </button>
      </span>
    </nav>
    """
  end

  # A branch is counted when a person looks at the branches, and never below them. Each
  # one is one query, and a source has three.
  defp root_counts(_module, [_segment | _rest]), do: %{}

  defp root_counts(module, []) do
    case module.roots() do
      {:error, _module} -> %{}
      roots -> Map.new(roots, fn {name, listing} -> {name, Ash.count!(listing.query)} end)
    end
  end

  attr :source, :any, required: true

  # A person who knows the name of a station or of a show does not want to walk a tree
  # for it. The tree is for browsing, and `PiFiWeb.SearchLive` is for finding.
  defp finder(assigns) do
    ~H"""
    <form id="finder" phx-submit="search" class="mb-4 flex items-center gap-2">
      <input
        type="search"
        name="text"
        autocomplete="off"
        placeholder={"Search #{@source.title()}…"}
        aria-label={"Search #{@source.title()}"}
        class="recess w-full rounded-lg border-0 px-3 py-2 text-sm text-ink placeholder:text-ink-faint focus:outline-none focus:ring-1 focus:ring-accent/60"
      />
      <button
        type="submit"
        id="do-search"
        aria-label="Search"
        class="control flex size-9 shrink-0 items-center justify-center rounded-lg"
      >
        <.icon name="ph-magnifying-glass" class="size-4" />
      </button>
    </form>
    """
  end

  attr :text, :string, default: nil

  # What a publisher wrote about one collection.
  #
  # **The line breaks are the publisher\'s, and HTML collapses them.** 43% of the
  # descriptions of one real library on 2026-09-14 held one, so a biography of five
  # paragraphs read as a single block of text. `whitespace-pre-line` draws them.
  #
  # **The length is not this page to choose, and it cannot all be drawn either.** That
  # same library gave a median of 1,793 bytes, 41% above 2,000, and a largest of 36,199.
  # The whole of one at the head of a list would bury the first row of it, so three
  # lines say what a thing is and a person who wants the rest presses.
  #
  # `<details>` is what holds that press, because it needs no state of the LiveView, no
  # JavaScript, and no event to reset when a person opens another collection.
  defp description(%{text: nil} = assigns), do: ~H""

  defp description(%{text: ""} = assigns), do: ~H""

  # **A description that three lines already hold draws no control**, or a person would
  # press `More` and read what they had already read. The count of the bytes is a guess
  # at what three lines hold, and it is a low one on purpose: a narrow screen fits fewer
  # words in a line, so a description near the edge gets the control it may need.
  defp description(%{text: text} = assigns) when byte_size(text) <= 120 do
    ~H"""
    <p class="mt-1 whitespace-pre-line text-xs text-ink-dim">{@text}</p>
    """
  end

  defp description(assigns) do
    ~H"""
    <details class="group mt-1">
      <summary class="cursor-pointer list-none [&::-webkit-details-marker]:hidden">
        <span class="line-clamp-3 whitespace-pre-line text-xs text-ink-dim group-open:line-clamp-none">
          {@text}
        </span>
        <span class="mt-0.5 block text-xs text-ink-faint group-hover:text-accent">
          <span class="group-open:hidden">More</span>
          <span class="hidden group-open:inline">Less</span>
        </span>
      </summary>
    </details>
    """
  end

  attr :item, :any, required: true
  attr :playable?, :boolean, required: true

  # The head of one collection: its picture, its name, and what the publisher says.
  #
  # **A collection of collections draws no play control.** A press on it would
  # mean "play every track of every album of this artist", and a person who opened an
  # artist asked to read the albums. `tracks_only?/1` answers that with one count.
  #
  # `description/1` holds what a publisher wrote, and why three lines of it.
  defp collection_header(assigns) do
    assigns = assign(assigns, :parent, parent(assigns.item))

    ~H"""
    <div id="collection-header" class="glass mb-3 flex items-start gap-3 rounded-xl p-3">
      <.cover
        path={Artwork.thumbnail_path(Map.get(@item, :artwork))}
        class="size-16 rounded-lg"
        icon_class="size-7"
      />

      <div class="min-w-0 grow">
        <p class="truncate font-medium text-ink">{@item.title}</p>
        <button
          :if={@parent}
          type="button"
          id="open-parent"
          phx-click="open_parent"
          phx-value-id={@parent.id}
          class="block max-w-full truncate rounded text-xs text-ink-faint hover:text-accent"
        >
          {@parent.title}
        </button>
        <p :if={is_nil(@parent) and @item.subtitle} class="truncate text-xs text-ink-faint">
          {@item.subtitle}
        </p>
        <.description text={@item.description} />
      </div>

      <div class="flex shrink-0 items-center gap-1">
        <.favourite row={@item} />

        <button
          :if={@playable?}
          type="button"
          id="queue-collection"
          phx-click="queue_collection"
          aria-label={"Add #{@item.title} to the queue"}
          class="control flex size-9 shrink-0 items-center justify-center rounded-full hover:text-accent"
        >
          <.icon name="ph-plus" class="size-4" />
        </button>

        <button
          :if={@playable?}
          type="button"
          id="play-collection"
          phx-click="play_collection"
          aria-label={"Play #{@item.title}"}
          class="control flex size-9 shrink-0 items-center justify-center rounded-full hover:text-accent"
        >
          <.icon name="ph-play" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  attr :layout, :atom, required: true

  # **The table is the view that a person gets when they have chosen nothing**, so the
  # control says which of the two is on and not what pressing it does.
  defp layout_choice(assigns) do
    ~H"""
    <div id="layout-choice" class="mb-2 flex items-center justify-end gap-1">
      <button
        :for={{layout, view, icon, label} <- layouts()}
        type="button"
        id={"layout-#{view}"}
        phx-click="layout"
        phx-value-view={view}
        aria-pressed={to_string(@layout == layout)}
        aria-label={label}
        class={[
          "control flex size-8 items-center justify-center rounded-lg",
          @layout == layout && "control-on text-accent"
        ]}
      >
        <.icon name={icon} class="size-4" />
      </button>
    </div>
    """
  end

  defp layouts do
    [
      {:table, "rows", "ph-list", "Show this as rows"},
      {:grid, "cards", "ph-squares-four", "Show this as cards"}
    ]
  end

  attr :source, :atom, required: true

  # **A source that receives audio has no tree**, so this stands where the branches
  # would. A person who pressed Spotify in the top row meant to reach Spotify, and a
  # page that drew nothing would read as a source that was broken. See
  # `t:PiFi.Source.unsupported/0`.
  defp receive_only(assigns) do
    ~H"""
    <div id="receive-only" class="glass rounded-xl p-6 text-center">
      <.source_icon name={@source.icon()} class="mx-auto size-8 text-accent" />

      <p class="mt-3 text-ink">
        There is nothing to browse here. Send audio to this device from
        {@source.title()} on your phone or computer, and it plays.
      </p>

      <.link navigate={~p"/settings/sources/#{Source.slug(@source)}"} class="mt-3 inline-block text-sm text-accent underline">
        {@source.title()} settings
      </.link>
    </div>
    """
  end

  attr :roots, :list, required: true
  attr :counts, :map, required: true

  defp roots(assigns) do
    ~H"""
    <ul id="entries" class="glass overflow-hidden rounded-xl">
      <li
        :for={{{name, _listing}, index} <- Enum.with_index(@roots)}
        class="flex items-center gap-2 border-b border-edge px-2 last:border-0"
      >
        <button
          type="button"
          id={"open-#{index}"}
          phx-click="open_root"
          phx-value-index={index}
          class="group flex min-w-0 grow items-center gap-3 py-3 text-left"
        >
          <.icon name="ph-folder" class="size-4 shrink-0 text-ink-faint" />
          <span class="min-w-0 grow truncate text-ink group-hover:text-accent">{name}</span>
          <.count of={Map.get(@counts, name, 0)} />
          <.icon
            name="ph-caret-right"
            class="size-4 shrink-0 text-ink-faint group-hover:text-accent"
          />
        </button>
      </li>
    </ul>
    """
  end

  # A sort, a filter and a page each give a new address, and none of them changes the
  # level. `walk/2` reads the database, and it asks a source to read a feed, so it runs
  # one time for each level and not one time for each press of a control.
  defp at(socket, module, segments) do
    if socket.assigns[:source] == module and socket.assigns[:segments] == segments do
      socket
    else
      path = walk(module, segments)
      opened = opened_item(%{path: path})

      socket
      |> start_at(module)
      |> assign(:segments, segments)
      |> assign(:collection_id, collection_id(segments))
      |> assign(:path, path)
      |> assign(:opened, opened)
      |> assign(:tracks_only?, tracks_only?(opened))
      |> assign(:root_counts, root_counts(module, segments))
    end
  end

  defp here(%{path: []}), do: nil

  defp here(%{path: path} = assigns),
    do: path |> List.last() |> Map.fetch!(:listing) |> starting_with(assigns[:letter])

  defp here(_assigns), do: nil

  # **The letter narrows the list, and it does not move a page of it.** These read
  # actions hold a keyset pagination, so a page has a cursor and no number, and there is
  # no page to jump to. A list of one letter is what a person who pressed G asked for in
  # any case, and it reads in the same order under the same sort.
  #
  # A facet carries a value of a union, which SQLite keeps as JSON text, so the bar draws
  # for the items alone. See `PiFi.Playback.Item`.
  defp starting_with(listing, nil), do: listing
  defp starting_with(%{kind: :facet} = listing, _letter), do: listing

  # `lower` of SQLite moves the letters of ASCII and no others, so `Ä` reads as a title
  # that begins with something that is not a letter. `title COLLATE NOCASE` gives the
  # same rule, which is what the order of this list already uses.
  defp starting_with(%{query: query} = listing, "#") do
    %{
      listing
      | query:
          Ash.Query.filter(
            query,
            fragment("substr(lower(?), 1, 1) not between 'a' and 'z'", title)
          )
    }
  end

  defp starting_with(%{query: query} = listing, letter) do
    down = String.downcase(letter)

    %{
      listing
      | query: Ash.Query.filter(query, fragment("substr(lower(?), 1, 1) = ?", title, ^down))
    }
  end

  # A hand can write anything in an address, and a letter that this bar does not hold
  # would narrow the list to nothing with no control to press to get it back.
  defp chosen_letter(letter) when is_binary(letter) do
    upper = String.upcase(letter)

    if upper in @letters, do: upper
  end

  defp chosen_letter(_letter), do: nil

  # A branch and a facet are lists that this page makes, and a container is a row of the
  # catalogue. Only a container names a thing that a source can read again.
  defp opened_item(%{path: []}), do: nil
  defp opened_item(%{path: path}), do: Map.get(List.last(path), :item)
  defp opened_item(_assigns), do: nil

  # **A collection draws a play control when every row of it plays.** An artist contains
  # albums, and `Playback.play/2` would then take a whole discography, which is not what
  # a person who opened an artist asked for.
  #
  # One count, and it runs when a person opens a level and not when a page draws. The
  # index of `parent_id` serves it, so the count reads no row of the table.
  defp tracks_only?(nil), do: false

  defp tracks_only?(%{id: id}) do
    containers =
      Item
      |> Ash.Query.filter(parent_id == ^id and kind == :container)
      |> Ash.count!()

    tracks =
      Item
      |> Ash.Query.filter(parent_id == ^id and kind == :track)
      |> Ash.count!()

    containers == 0 and tracks > 0
  end

  # See `PiFi.Source.refresh/2`. The source says whether it reads a service, so this
  # page needs no knowledge of podcasts.
  defp refreshable?(%{source: nil}), do: false

  defp refreshable?(assigns) do
    not is_nil(opened_item(assigns)) and :refresh in assigns.source.capabilities()
  end

  # Cinder keeps the sort and the filters of one collection, and a level of facets and a
  # level of items are two resources. One identifier for both gives a sort of `title` to
  # a query of `PiFi.Playback.Facet`, which has no such field. Each level therefore
  # gets an identifier of its own, and a new list starts with no sort and no filter.
  defp collection_id(segments), do: Enum.map_join([@collection | segments], "-", &slug/1)

  # A facet is named by its value, and an item by its title. `sorted_title` is the
  # title in the order of the letters, and `title` gives the order of the bytes. See
  # `PiFi.Playback.Item`.
  defp field(:facet), do: "value"
  defp field(:item), do: "sorted_title"

  # **The text filter of Cinder matches the case on AshSqlite**, so a person who typed
  # `rock` found no `Rock`. `PiFiWeb.ItemList.filter_title/2` builds the expression
  # that the search page reads as well, and it says why. A facet carries a value of a
  # union and not a title, so it keeps the filter that Cinder gives.
  defp filter(:facet), do: true
  defp filter(:item), do: [type: :text, fn: &ItemList.filter_title/2]

  # Each level counts what its rows hold. Cinder keeps what `query_opts` names, and Ash
  # gives the whole page to the calculation in one call.
  defp counts(:facet), do: :item_count
  defp counts(:item), do: :child_count

  # A row of a container draws its picture, and `artwork` is the calculation that gives
  # the address: the picture of the item, or the picture of the container above it.
  # One call of Ash serves the whole page, so this costs one expression and no query for
  # each row. A facet is a value and it has no picture.
  defp loads(:facet), do: [counts(:facet)]

  # **A fact of a row is a field or a calculation, and a read that does not name a
  # calculation gives `%Ash.NotLoaded{}`.** `remaining_ms` is one, and so is the count
  # of the children, so this names both for every list rather than ask each source
  # which of them it draws. See `c:PiFi.Source.listing/1`.
  defp loads(:item), do: [counts(:item), :artwork, :remaining_ms, :audio_held?]

  # The filter and the sort name what a person looks at. `Value` is the field of the
  # facet, and it says nothing to a person who opened Countries. A list of artists draws
  # names and not titles, so a listing names the word for its own rows. See
  # `t:PiFi.Source.listing/0`.
  defp label(path, %{kind: :facet}), do: List.last(path).title
  defp label(_path, listing), do: listing[:title_label] || "Title"

  # A facet is named by its value, which reads far better in an address than an
  # identifier does.
  defp open_facet(socket, id) do
    case Ash.get(Facet, id) do
      {:ok, facet} -> go(socket, socket.assigns.segments ++ [to_string(facet.value.value)])
      {:error, _reason} -> socket
    end
  end

  # An item has no name that an address can use, so its identifier is the segment.
  defp open_item(socket, id) do
    case Playback.get_item(id) do
      {:ok, %{kind: :container}} -> go(socket, socket.assigns.segments ++ [id])
      _other -> socket
    end
  end

  # **A letter belongs to the list that a person set it on**, as a sort does, so a level
  # change takes it away. A person who pressed G under Albums did not ask for the artists
  # of G as well.
  defp go(socket, segments) do
    socket =
      if segments == socket.assigns.segments, do: socket, else: assign(socket, :letter, nil)

    push_patch(socket, to: address(socket, segments))
  end

  # An empty list gives the address of the source, and not one with a slash on the end of
  # it. `find` says that the controls are in sight, and it stays through a level change,
  # because it is what a person chose and not a part of the level.
  defp address(socket, segments) do
    source = socket.assigns.current_source
    query = Map.merge(find_param(socket.assigns.finding?), letter_param(socket.assigns.letter))

    case segments do
      [] -> ~p"/browse/#{source}?#{query}"
      _other -> ~p"/browse/#{source}/#{segments}?#{query}"
    end
  end

  # **A press of a letter keeps the sort and the filter of the person.** The bar draws
  # beside those two controls, so a person who sorted by date and then pressed G asked
  # for the G of that order. `address/2` builds the address of a level and it keeps
  # neither, so this one changes the address that the page is on.
  #
  # The cursor of the page goes, because it names a row of the list before the letter
  # narrowed it. See `Cinder.UrlSync`, which keeps a parameter that it does not know and
  # is the other half of this.
  defp letter_address(socket, letter) do
    uri = URI.parse(socket.assigns.url_state.uri)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.drop(@cursor_params)
      |> put_letter(letter)

    if query == %{}, do: uri.path, else: "#{uri.path}?#{URI.encode_query(query)}"
  end

  defp put_letter(query, nil), do: Map.delete(query, "letter")
  defp put_letter(query, letter), do: Map.put(query, "letter", letter)

  # **The layout is a parameter of the page, in the way that the letter is.** A reload
  # and a bookmark therefore keep it, and `Cinder.UrlSync` keeps a parameter that it
  # does not know. See `letter_address/2`.
  #
  # It keeps the cursor of the page. A layout draws the same rows in another shape, so
  # the row that a person is looking at is still in the list.
  defp layout_address(socket, layout) do
    uri = URI.parse(socket.assigns.url_state.uri)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> put_layout(layout)

    if query == %{}, do: uri.path, else: "#{uri.path}?#{URI.encode_query(query)}"
  end

  # The table is what a person gets when they have chosen nothing, so it needs no
  # parameter and the address of it stays short.
  defp put_layout(query, :table), do: Map.delete(query, "view")
  defp put_layout(query, :grid), do: Map.put(query, "view", "cards")

  defp chosen_layout("cards"), do: :grid
  defp chosen_layout(_other), do: :table

  defp find_param(true), do: %{find: 1}
  defp find_param(false), do: %{}

  defp letter_param(nil), do: %{}
  defp letter_param(letter), do: %{letter: letter}

  # Walk the same two steps that a person walked, one segment at a time. A segment that
  # names nothing ends the walk, so a stale bookmark gives the level that still stands
  # and not an error.
  defp walk(source, segments) do
    Enum.reduce_while(segments, [], fn segment, path ->
      case step(source, List.last(path), segment) do
        nil -> {:halt, path}
        crumb -> {:cont, path ++ [crumb]}
      end
    end)
  end

  # A branch, or a container by its identifier. `PiFiWeb.SearchLive` finds a show
  # that no branch of this source names, so the address of a container cannot need one.
  defp step(source, nil, segment) do
    with roots when is_list(roots) <- source.roots(),
         {name, listing} <- Enum.find(roots, fn {name, _listing} -> slug(name) == segment end) do
      %{title: name, listing: listing}
    else
      _other -> container(source, segment)
    end
  end

  # **The source names the order of these rows and the facts that they draw**, and this
  # page needs no knowledge of any source. `nil` is what a list under a facet is: no
  # container is above it. See `c:PiFi.Source.listing/1`.
  #
  # **The row of the facet comes first, and the items follow from it.** The branch above
  # holds the query of its own facets, so a value of the address names one row of that
  # branch and this needs no knowledge of the key that the source chose. The identifier
  # of that row then names the source as well, which is why the read below carries no
  # filter on it. See the `:by_facet` action of `PiFi.Playback.Item`.
  defp step(source, %{listing: %{kind: :facet, query: facets}}, segment) do
    case Ash.read_one(Ash.Query.filter(facets, value == ^segment)) do
      {:ok, %Facet{} = facet} -> under(source, facet, segment)
      _other -> nil
    end
  end

  defp step(source, %{listing: %{kind: :item}}, segment), do: container(source, segment)

  # The items of one facet, in the order that the source names.
  defp under(source, facet, segment) do
    inside = Source.inside(source, nil)

    query =
      Item
      |> Ash.Query.for_read(:by_facet, %{facet_id: facet.id})
      |> Ash.Query.sort(inside[:sort] || [])

    %{title: segment, listing: Map.merge(inside, %{query: query, kind: :item})}
  end

  # A container opens into the items whose `parent_id` names it. The source must match,
  # so an identifier of one source cannot open under another one.
  #
  # **The source names the order and the facts.** An album reads its tracks by number
  # and a show reads its episodes by date, and this page cannot carry either rule: it
  # sorted every container by date, so every album of a Jellyfin library listed
  # alphabetically. See `c:PiFi.Source.listing/1`.
  #
  # An item with no value comes before all of them, because SQLite reads an absent one
  # as the smallest. `:asc_nils_last` says otherwise, and Cinder reads no direction but
  # `:asc` and `:desc`, so it would drop the sort and leave the alphabet.
  defp container(source, id) do
    slug = Source.slug(source)

    # `artwork` is a calculation, and the head of the collection draws it. A read that
    # does not name it returns `%Ash.NotLoaded{}`, and the head then drew a folder for a
    # container that has a picture. The head names the container above this one
    # as well, so `parent` comes with it.
    case Playback.get_item(id, load: [:artwork, :parent]) do
      {:ok, %{kind: :container, source: ^slug} = item} ->
        opened(source, item)
        inside = Source.inside(source, item)

        query =
          Item
          |> Ash.Query.filter(parent_id == ^item.id)
          |> Ash.Query.sort(inside[:sort] || [])

        %{
          title: item.title,
          item: item,
          listing: Map.merge(inside, %{query: query, kind: :item})
        }

      _other ->
        nil
    end
  end

  # The container above this one, when the catalogue has one. An album names its
  # artist, and a show at the top of its source names nothing.
  defp parent(%{parent: %Item{kind: :container} = parent}), do: parent
  defp parent(_item), do: nil

  # A branch is named by its name, in lower case with a dash for each space.
  defp slug(name), do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

  # A source that must reach a service when a container opens says so. See
  # `PiFi.Source.opened/1`.
  defp opened(source, item) do
    if function_exported?(source, :opened, 1), do: source.opened(item), else: :ok
  end

  # An address with no source is a person who asked for "the device", so the device
  # answers with the switch where they left it. See `PiFi.Source.chosen/0`.
  defp chosen_source(socket) do
    case Source.chosen() do
      nil -> start_at(socket, nil)
      module -> push_navigate(socket, to: ~p"/browse/#{Source.slug(module)}")
    end
  end

  defp start_at(socket, nil) do
    socket
    |> assign(:source, nil)
    |> assign(:searchable?, false)
    |> assign(:current_source, nil)
    |> assign(:roots, [])
    |> assign(:path, [])
    |> assign(:segments, [])
  end

  defp start_at(socket, module) do
    socket
    |> assign(:source, module)
    |> assign(:searchable?, :search in module.capabilities())
    |> assign(:current_source, Source.slug(module))
    |> assign(:page_title, module.title())
    |> assign(:roots, module.roots())
  end

  defp to_index(index) when is_binary(index), do: String.to_integer(index)
  defp to_index(index) when is_integer(index), do: index
end
