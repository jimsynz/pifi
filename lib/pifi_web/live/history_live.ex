defmodule PiFiWeb.HistoryLive do
  @moduledoc """
  What this device has played, the most recent first.

  A person hears something and wants it again, and the branch that they found it under
  may take a while to reach: a track of an album of an artist is three presses, and a
  station under a country is two. This page is one.

  **It holds one row for each item and not one for each play.** A person who played an
  album twelve times wants to find the album, and twelve rows of it would push
  everything else off the page. `last_started_at` of `PiFi.Playback.Item` is
  therefore the last time and not a list of times.

  **It reads every source together, and the row says which one.** A history that a
  person had to choose a source for would answer the wrong question: they remember the
  music and not the service that holds it.

  A row of a source that a person took out of use is absent, because such a row cannot
  play. See `PiFi.Source.enabled?/1`.
  """

  use PiFiWeb, :live_view

  alias PiFi.Playback
  alias PiFi.Source
  alias PiFiWeb.ItemList

  import PiFiWeb.ItemList, only: [playlist_sheet: 1, row: 1]

  require Ash.Query

  on_mount(PiFiWeb.ItemList)

  @collection "history"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "History")
     |> assign(:collection_id, @collection)
     |> assign(:current_source, nil)
     |> assign(:list_query, nil)
     |> assign(:url_state, nil)
     |> assign(:query, query())}
  end

  @impl Phoenix.LiveView
  def handle_params(params, uri, socket) do
    {:noreply, Cinder.UrlSync.handle_params(params, uri, socket)}
  end

  # A container never plays, so it opens. The row carries its own source, because this
  # page holds the rows of every one of them.
  @impl Phoenix.LiveView
  def handle_event("open", %{"id" => id}, socket) do
    case Playback.get_item(id) do
      {:ok, item} -> {:noreply, push_navigate(socket, to: ~p"/browse/#{item.source}/#{[id]}")}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:list_query, %{query: query}}, socket) do
    {:noreply, assign(socket, :list_query, query)}
  end

  # This is the clause that `use Cinder.UrlSync` writes. This page writes it out, for
  # the reason that `PiFiWeb.BrowseLive` gives.
  def handle_info({:table_state_change, _id, state}, socket) do
    {:noreply,
     Cinder.UrlSync.update_url(socket, state, get_in(socket.assigns, [:url_state, :uri]))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # A source that a person took out of use holds no row here. `in` takes the slugs and
  # not the modules, because `source` of an item is the slug.
  defp query do
    slugs = Enum.map(Source.enabled(), &Source.slug/1)

    Playback.Item
    |> Ash.Query.for_read(:history)
    |> Ash.Query.filter(source in ^slugs)
  end

  # The row draws the mark of the source, so a person reads where each one came from.
  defp source_of(item) do
    case Source.from_slug(item.source) do
      {:ok, module} -> module
      {:error, _reason} -> nil
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div id="history">
      <.playlist_sheet adding={@adding} playlists={@playlists} />

      <Cinder.collection
        id={@collection_id}
        query={@query}
        layout={:list}
        url_state={@url_state}
        page_size={25}
        empty_message="This device has played nothing yet."
        loading_message="Reading…"
        filters_label="Find"
        sort_label="Sort"
        show_filters={true}
        search={[label: "Name", placeholder: "Search the history…", fn: &ItemList.search_title/3]}
        query_opts={[load: [:child_count, :artwork, :audio_held?]]}
        on_query_change={:list_query}
      >
        <:col field="sorted_title" label="Title" search />
        <:col field="last_started_at" label="Heard" sort />

        <:item :let={item}>
          <.row
            :if={source_of(item)}
            row={item}
            playing={@playing}
            source={source_of(item)}
            facts={[:subtitle]}
            reading={@reading}
          />
        </:item>
      </Cinder.collection>
    </div>
    """
  end
end
