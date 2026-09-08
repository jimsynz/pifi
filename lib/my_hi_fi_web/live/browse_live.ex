defmodule MyHiFiWeb.BrowseLive do
  @moduledoc """
  Find something to play.

  The address names the source, and the top row of the faceplate holds one control for
  each source. `MyHiFi.Source.roots/0` gives the branches of that source, and
  everything below them is generic: this page holds no knowledge of internet radio and
  none of podcasts.

  ## Two rules make the whole tree

  A row of `MyHiFi.Playback.Facet` opens into the items that link to it. An item of the
  kind `:container` opens into the items whose `parent_id` names it. A source takes no
  part in either one, which is what one catalogue is for.

  ## What Cinder holds, and what this page holds

  `Cinder` runs the query. It holds the loading state, the sort, the filters and the
  page controls, so this page holds none of that: no cursor, no page of entries, and no
  read of a list inside `handle_event`. A slow read draws a loading state, which the
  page before this one did not.

  This page holds the breadcrumbs and the marker of the track that plays, because
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
  """

  use MyHiFiWeb, :live_view

  require Ash.Query

  alias MyHiFi.Artwork
  alias MyHiFi.Playback
  alias MyHiFi.Playback.Facet
  alias MyHiFi.Playback.Item
  alias MyHiFi.Source

  import MyHiFiWeb.ItemList, only: [row: 1, count: 1, cover: 1, favourite: 1]

  on_mount(MyHiFiWeb.ItemList)

  @collection "browse"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Browse")
     |> assign(:finding?, false)
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
      # on it. Do not put what it gives into an assign.
      {:noreply,
       socket
       |> assign(:finding?, params["find"] == "1")
       |> at(module, params["path"] || [])
       |> then(&Cinder.UrlSync.handle_params(params, uri, &1))}
    else
      _other -> {:noreply, chosen_source(socket)}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _uri, socket), do: {:noreply, chosen_source(socket)}

  @impl Phoenix.LiveView
  def handle_event("open_root", %{"index" => index}, socket) do
    {name, _listing} = Enum.at(socket.assigns.roots, to_index(index))

    {:noreply, go(socket, socket.assigns.segments ++ [slug(name)])}
  end

  # A facet opens into the items that hold it, and a container opens into what it
  # holds. Neither rule needs the source.
  def handle_event("open", %{"id" => id}, socket) do
    case here(socket.assigns) do
      %{kind: :facet} -> {:noreply, open_facet(socket, id)}
      %{kind: :item} -> {:noreply, open_item(socket, id)}
      nil -> {:noreply, socket}
    end
  end

  # **A person reaches an album from the list of albums, from the favourites and from a
  # search, and no crumb of those paths names the artist.** The head of the collection
  # therefore draws the container that holds this one, and this opens it.
  #
  # The address holds that identifier and nothing above it, because a container opens
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

  # A person who will not wait for the schedule asks for the read now. The source
  # publishes `MyHiFi.Event.Source.Changed` when it finishes, and the list then reads
  # itself again.
  def handle_event("refresh", _params, socket) do
    case Source.refresh(socket.assigns.source, opened_item(socket.assigns)) do
      :ok ->
        {:noreply, put_flash(socket, :info, "The device reads this again now.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The device could not read this again.")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("crumb", %{"index" => index}, socket) do
    {:noreply, go(socket, Enum.take(socket.assigns.segments, to_index(index)))}
  end

  # A person types a name, and the tree is not what finds it. See `MyHiFiWeb.SearchLive`.
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
  # it. `MyHiFiWeb.ItemList` reads it when a person presses play, so the list that they
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
        This firmware holds no source.
      </p>

      <div :if={@source}>
        <.crumbs
          path={@path}
          source={@source}
          finding?={@finding?}
          collection?={not is_nil(@here)}
          refreshable?={@refreshable?}
        />

        <.finder :if={is_nil(@here) and @searchable?} source={@source} />

        <.roots :if={is_nil(@here)} roots={@roots} counts={@root_counts} />

        <.collection_header :if={@opened} item={@opened} playable?={@tracks_only?} />

        <Cinder.collection
          :if={@here}
          id={@collection_id}
          query={@here.query}
          layout={:list}
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
          <:col
            :if={@here[:order]}
            field={@here[:order] && elem(@here[:order], 1)}
            label={@here[:order] && elem(@here[:order], 0)}
            sort
          />

          <:col field={field(@here.kind)} label={label(@path, @here.kind)} sort filter />

          <:item :let={row}>
            <.row
              row={row}
              kind={@here.kind}
              playing={@playing}
              source={@source}
              number?={@here[:number?] || false}
              facts={@here[:facts] || []}
              reading={@reading}
            />
          </:item>
        </Cinder.collection>
      </div>
    </div>
    """
  end

  attr :path, :list, required: true
  attr :source, :any, required: true
  attr :finding?, :boolean, required: true
  attr :collection?, :boolean, required: true
  attr :refreshable?, :boolean, required: true

  defp crumbs(assigns) do
    ~H"""
    <nav
      id="crumbs"
      aria-label="Where you are"
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
          if(@path == [], do: "text-ink", else: "text-ink-dim hover:text-accent")
        ]}
      >
        {@source.title()}
      </button>

      <span :for={{crumb, index} <- Enum.with_index(@path)} class="flex items-center gap-1">
        <.icon name="hero-chevron-right-micro" class="size-3 text-ink-faint" />
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
          aria-label="Read this again"
          class="control flex size-8 shrink-0 items-center justify-center rounded-lg"
        >
          <.icon name="hero-arrow-path" class="size-4" />
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
          <.icon name="hero-adjustments-horizontal" class="size-4" />
        </button>
      </span>
    </nav>
    """
  end

  # A branch is counted when a person looks at the branches, and never below them. Each
  # one is one query, and a source holds three.
  defp root_counts(_module, [_segment | _rest]), do: %{}

  defp root_counts(module, []) do
    Map.new(module.roots(), fn {name, listing} -> {name, Ash.count!(listing.query)} end)
  end

  attr :source, :any, required: true

  # A person who knows the name of a station or of a show does not want to walk a tree
  # for it. The tree holds the browsing, and `MyHiFiWeb.SearchLive` holds the finding.
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
        aria-label="Find"
        class="control flex size-9 shrink-0 items-center justify-center rounded-lg"
      >
        <.icon name="hero-magnifying-glass" class="size-4" />
      </button>
    </form>
    """
  end

  attr :item, :any, required: true
  attr :playable?, :boolean, required: true

  # The head of one collection: its picture, its name, and what the publisher says.
  #
  # **A collection that holds collections holds no play control.** A press on it would
  # mean "play every track of every album of this artist", and a person who opened an
  # artist asked to read the albums. `tracks_only?/1` answers that with one count.
  #
  # The description is what a publisher wrote, so its length is not this page to choose.
  # Three lines is enough to know what a thing is, and it leaves the first rows of the
  # list in sight on a telephone.
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
        <p :if={@item.description} class="mt-1 line-clamp-3 text-xs text-ink-dim">
          {@item.description}
        </p>
      </div>

      <div class="flex shrink-0 items-center gap-1">
        <.favourite row={@item} />

        <button
          :if={@playable?}
          type="button"
          id="play-collection"
          phx-click="play_collection"
          aria-label={"Play #{@item.title}"}
          class="control flex size-9 shrink-0 items-center justify-center rounded-full hover:text-accent"
        >
          <.icon name="hero-play-mini" class="size-4" />
        </button>
      </div>
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
          <.icon name="hero-folder" class="size-4 shrink-0 text-ink-faint" />
          <span class="min-w-0 grow truncate text-ink group-hover:text-accent">{name}</span>
          <.count of={Map.get(@counts, name, 0)} />
          <.icon
            name="hero-chevron-right-mini"
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
  defp here(%{path: path}), do: List.last(path).listing
  defp here(_assigns), do: nil

  # A branch and a facet are lists that this page makes, and a container is a row of the
  # catalogue. Only a container names a thing that a source can read again.
  defp opened_item(%{path: []}), do: nil
  defp opened_item(%{path: path}), do: Map.get(List.last(path), :item)
  defp opened_item(_assigns), do: nil

  # **A collection holds a play control when every row of it plays.** An artist holds
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

  # See `MyHiFi.Source.refresh/2`. The source says whether it reads a service, so this
  # page holds no knowledge of podcasts.
  defp refreshable?(%{source: nil}), do: false

  defp refreshable?(assigns) do
    not is_nil(opened_item(assigns)) and :refresh in assigns.source.capabilities()
  end

  # Cinder keeps the sort and the filters of one collection, and a level of facets and a
  # level of items are two resources. One identifier for both gives a sort of `title` to
  # a query of `MyHiFi.Playback.Facet`, which holds no such field. Each level therefore
  # gets an identifier of its own, and a new list starts with no sort and no filter.
  defp collection_id(segments), do: Enum.map_join([@collection | segments], "-", &slug/1)

  # A facet is named by its value, and an item by its title.
  defp field(:facet), do: "value"
  defp field(:item), do: "title"

  # Each level counts what its rows hold. Cinder keeps what `query_opts` names, and Ash
  # gives the whole page to the calculation in one call.
  defp counts(:facet), do: :item_count
  defp counts(:item), do: :child_count

  # A row of a container draws its picture, and `artwork` is the calculation that gives
  # the address: the picture of the item, or the picture of the container that holds it.
  # One call of Ash serves the whole page, so this costs one expression and no query for
  # each row. A facet is a value and it holds no picture.
  defp loads(:facet), do: [counts(:facet)]

  # **A fact of a row is a field or a calculation, and a read that does not name a
  # calculation gives `%Ash.NotLoaded{}`.** `remaining_ms` is one, and so is the count
  # of the children, so this names both for every list rather than ask each source
  # which of them it draws. See `c:MyHiFi.Source.listing/1`.
  defp loads(:item), do: [counts(:item), :artwork, :remaining_ms, :audio_held?]

  # The filter and the sort name what a person looks at. `Value` is the field of the
  # facet, and it says nothing to somebody who opened Countries.
  defp label(path, :facet), do: List.last(path).title
  defp label(_path, :item), do: "Title"

  # A facet is named by its value, which reads far better in an address than an
  # identifier does.
  defp open_facet(socket, id) do
    case Ash.get(Facet, id) do
      {:ok, facet} -> go(socket, socket.assigns.segments ++ [to_string(facet.value.value)])
      {:error, _reason} -> socket
    end
  end

  # An item holds no name that an address can use, so its identifier is the segment.
  defp open_item(socket, id) do
    case Playback.get_item(id) do
      {:ok, %{kind: :container}} -> go(socket, socket.assigns.segments ++ [id])
      _other -> socket
    end
  end

  defp go(socket, segments), do: push_patch(socket, to: address(socket, segments))

  # An empty list gives the address of the source, and not one with a slash on the end of
  # it. `find` says that the controls are in sight, and it stays through a level change,
  # because it is what a person chose and not a part of the level.
  defp address(socket, segments) do
    source = socket.assigns.current_source
    query = if socket.assigns.finding?, do: %{find: 1}, else: %{}

    case segments do
      [] -> ~p"/browse/#{source}?#{query}"
      _other -> ~p"/browse/#{source}/#{segments}?#{query}"
    end
  end

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

  # A branch, or a container by its identifier. `MyHiFiWeb.SearchLive` finds a show
  # that no branch of this source holds, so the address of a container cannot need one.
  defp step(source, nil, segment) do
    case Enum.find(source.roots(), fn {name, _listing} -> slug(name) == segment end) do
      {name, listing} -> %{title: name, listing: listing}
      nil -> container(source, segment)
    end
  end

  # **The source names the order of these rows and the facts that they draw**, and this
  # page holds no knowledge of any source. `nil` is what a list under a facet is: no
  # container holds it. See `c:MyHiFi.Source.listing/1`.
  defp step(source, %{listing: %{kind: :facet}}, segment) do
    inside = Source.inside(source, nil)

    query =
      Item
      |> Ash.Query.filter(source == ^Source.slug(source) and exists(facets, value == ^segment))
      |> Ash.Query.sort(inside[:sort] || [])

    %{title: segment, listing: Map.merge(inside, %{query: query, kind: :item})}
  end

  defp step(source, %{listing: %{kind: :item}}, segment), do: container(source, segment)

  # A container opens into the items whose `parent_id` names it. The source must match,
  # so an identifier of one source cannot open under another one.
  #
  # **The source names the order and the facts.** An album holds its tracks by number
  # and a show holds its episodes by date, and this page cannot hold either rule: it
  # sorted every container by date, so every album of a Jellyfin library listed
  # alphabetically. See `c:MyHiFi.Source.listing/1`.
  #
  # An item with no value comes before all of them, because SQLite reads an absent one
  # as the smallest. `:asc_nils_last` says otherwise, and Cinder reads no direction but
  # `:asc` and `:desc`, so it would drop the sort and leave the alphabet.
  defp container(source, id) do
    slug = Source.slug(source)

    # `artwork` is a calculation, and the head of the collection draws it. A read that
    # does not name it gives `%Ash.NotLoaded{}`, and the head then drew a folder for a
    # container that holds a picture. The head names the container that holds this one
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

  # The container that holds this one, when the catalogue holds one. An album names its
  # artist, and a show at the top of its source names nothing.
  defp parent(%{parent: %Item{kind: :container} = parent}), do: parent
  defp parent(_item), do: nil

  # A branch is named by its name, in lower case with a dash for each space.
  defp slug(name), do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

  # A source that must reach a service when a container opens says so. See
  # `MyHiFi.Source.opened/1`.
  defp opened(source, item) do
    if function_exported?(source, :opened, 1), do: source.opened(item), else: :ok
  end

  # An address with no source is a person who asked for "the device", so the device
  # answers with the switch where they left it. See `MyHiFi.Source.chosen/0`.
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
