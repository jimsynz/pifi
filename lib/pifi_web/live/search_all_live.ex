defmodule PiFiWeb.SearchAllLive do
  @moduledoc """
  Find an item in every source that a person left in use.

  `PiFiWeb.SearchLive` searches one source and draws one collection. This page draws
  a heading for each group that a source names, with the count beside it and the first
  few rows under it, and a person who presses a heading reads that group alone.

  `c:PiFi.Source.search_groups/1` names the groups, so this page holds no knowledge
  of any source. A library names artists, albums and tracks; podcasts names shows and
  episodes; internet radio names stations.

  ## The text is in the address, and a person submits it

  `/search?search=alt` is what a person reads, so a reload and a bookmark both work, in
  the way that they do on the page of one source.

  **This page reads on a submit, and not on each letter.** A group costs a count and a
  read of the first rows, and neither one can use an index: the match is
  `instr(lower(title), lower(?))`, and a text in the middle of a title needs every row.
  A measurement of a table of 137,575 rows on a board on 2026-09-14 gave 80 to 109 ms
  for the count of one group and 343 ms for the first three rows of it. A page of nine
  groups that read on each letter would ask the card for 18 of those for every letter
  that a person types.

  ## The groups read at the same time

  Nine groups, one after another, took about 4 seconds of that measurement.
  `PRAGMA journal_mode` of the board answers `wal`, so readers do not wait for each
  other, and `Task.async_stream/3` reads the groups together instead. The order of the
  answer is the order of the groups, because that stream keeps it.
  """

  use PiFiWeb, :live_view

  alias PiFi.Source
  alias PiFiWeb.ItemList

  import PiFiWeb.ItemList, only: [playlist_sheet: 1, row: 1]

  on_mount(PiFiWeb.ItemList)

  # How many rows of a group a person reads before they press the heading of it. Three
  # is what the heading needs to be worth pressing, and it keeps the page short for a
  # device that holds nine groups.
  @rows 3

  # A group of a library holds thousands of rows, and no person reads a count of five
  # figures. This is what one group reads at most, so a count of more than it draws
  # `999+` and the card reads no further.
  @count_limit 999

  # **Four, because each connection of the pool holds a page cache of 4 MB.** A read
  # fills that cache the first time it touches a table, so four groups at once is the
  # 16 MB ceiling that `config/target.exs` chose for this database. A board that read
  # nine groups at once would hold more than twice that, on a board where Linux sees
  # 363.9 MB.
  @at_once 4

  # A group that answers no faster than this leaves the page without it, so one slow
  # read cannot hold the whole page. Nothing plays from this page until a person presses
  # a row, so a group that is absent costs them a second search and nothing more.
  @group_timeout :timer.seconds(10)

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Search")
     |> assign(:text, "")
     |> assign(:groups, [])
     |> assign(:searched?, false)}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    text = params["search"] || ""

    {:noreply,
     socket
     |> assign(:text, text)
     |> assign(:searched?, text != "")
     |> assign(:groups, groups(text))}
  end

  @impl Phoenix.LiveView
  def handle_event("search", %{"search" => text}, socket) do
    {:noreply, push_patch(socket, to: ~p"/search?#{[search: text]}")}
  end

  # A container never plays, so it opens. The browse page addresses one by its
  # identifier, with no branch above it, in the way that `PiFiWeb.SearchLive` does.
  #
  # **This page holds rows of more than one source**, so the address needs the source of
  # the row that a person pressed. The row carries it, and the groups on the page hold
  # the row, so this costs no query.
  @impl Phoenix.LiveView
  def handle_event("open", %{"id" => id}, socket) do
    case Enum.find_value(socket.assigns.groups, &slug_of(&1, id)) do
      nil -> {:noreply, socket}
      slug -> {:noreply, push_navigate(socket, to: ~p"/browse/#{slug}/#{[id]}")}
    end
  end

  defp slug_of(group, id) do
    if Enum.any?(group.rows, &(&1.id == id)), do: group.slug
  end

  @impl Phoenix.LiveView
  def handle_info(_message, socket), do: {:noreply, socket}

  # A text of nothing reads nothing. A person who opens this page sees the field and no
  # list, and the card answers no query for them.
  defp groups(""), do: []

  defp groups(text) do
    Source.enabled()
    |> Enum.filter(&(:search in &1.capabilities()))
    |> Enum.flat_map(fn module ->
      Enum.map(Source.search_groups(module, text), &{module, &1})
    end)
    |> Task.async_stream(&read(&1, text),
      max_concurrency: @at_once,
      timeout: @group_timeout,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, group} -> List.wrap(group)
      {:exit, _reason} -> []
    end)
  end

  # A group with no row is absent. A person who searches for a word that no album holds
  # must read the groups that answered, and not a column of empty headings.
  defp read({module, {label, listing}}, text) do
    query = ItemList.search_title(listing.query, [], text)

    case Ash.read!(query,
           page: [limit: @rows, count: false],
           load: [:child_count, :artwork, :audio_held?]
         ) do
      %{results: []} ->
        nil

      %{results: rows} ->
        %{
          id: "#{Source.slug(module)}-#{Macro.underscore(label)}",
          label: label,
          source: module,
          slug: Source.slug(module),
          facts: Map.get(listing, :facts, []),
          count: count(query),
          rows: rows
        }
    end
  end

  # **The count stops at a number that a person can read.** A count of every match of
  # a library reads every row of it, and the answer says no more than `999+` does.
  defp count(query) do
    query
    |> Ash.Query.limit(@count_limit + 1)
    |> Ash.count!()
  end

  defp counted(count) when count > @count_limit, do: "#{@count_limit}+"
  defp counted(count), do: to_string(count)

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div id="search-all">
      <.playlist_sheet adding={@adding} playlists={@playlists} />

      <form id="search-all-form" phx-submit="search" class="mb-4 flex items-center gap-2">
        <.input
          type="text"
          name="search"
          value={@text}
          placeholder="Search every source…"
          aria-label="Search every source"
          class="grow"
        />
        <button
          type="submit"
          id="search-all-submit"
          class="control flex shrink-0 items-center rounded-lg p-2"
          aria-label="Search"
        >
          <.icon name="ph-magnifying-glass" class="size-5" />
        </button>
      </form>

      <p :if={not @searched?} id="search-all-prompt" class="text-sm text-ink-dim">
        Type something and press search.
      </p>

      <p :if={@searched? and @groups == []} id="search-all-empty" class="text-sm text-ink-dim">
        No matches.
      </p>

      <section :for={group <- @groups} id={"group-#{group.id}"} class="mb-5">
        <.link
          navigate={~p"/search/#{group.slug}?#{[search: @text, group: group.label]}"}
          id={"heading-#{group.id}"}
          class="mb-1 flex items-baseline gap-2 text-sm hover:text-accent"
        >
          <span class="grow truncate font-medium text-ink">{group.label}</span>
          <span class="text-xs uppercase tracking-[0.18em] text-ink-faint">
            {group.source.title()}
          </span>
          <span class="numerals shrink-0 text-ink-dim">({counted(group.count)})</span>
        </.link>

        <div :for={item <- group.rows} class="py-0.5">
          <.row
            row={item}
            playing={@playing}
            source={group.source}
            facts={group.facts}
            reading={@reading}
          />
        </div>
      </section>
    </div>
    """
  end
end
