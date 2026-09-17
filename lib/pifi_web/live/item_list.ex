defmodule PiFiWeb.ItemList do
  @moduledoc """
  What a page needs to draw a list of `PiFi.Playback.Item` and play from it.

  `PiFiWeb.BrowseLive` and `PiFiWeb.SearchLive` both draw such a list, and a row of
  one is the same row on both. This module draws the rows and the controls, so a change
  to a row reaches each page.

  ## How a page uses it

      use PiFiWeb, :live_view

      on_mount PiFiWeb.ItemList
      import PiFiWeb.ItemList, only: [row: 1, count: 1]

  `on_mount/1` subscribes to the sources, assigns `:playing`, and answers the `play`,
  the `favourite` and the `played` events and every event of the player. A page
  therefore needs none of that.

  **`PiFiWeb.Shell` owns the subscription to the `:player` topic**, and this hook
  takes it again for nothing: two subscriptions of one process give two copies of each
  event, and a page then reads a `PiFi.Event.Player.Progress` twice each second. A
  hook reads every message of the process that it runs in, whichever part asked for the
  topic, so the clauses below need no subscription of their own.

  ## A list that changed while nobody looked

  A source reads a service behind the page, so what a container contains changes while a
  person is elsewhere. `PiFi.Event.Source.Changed` says so, and this hook reads the
  list again for it.

  **A device in standby reads nothing.** `PiFiWeb.Layouts` draws no list at all in
  standby, so a read then costs the card and the cores and gives no person anything.
  One query of a browse page touched 38 MB of page cache on this board, which is why
  `config/target.exs` keeps the SQLite cache small, and standby is the moment that the
  device is quiet in. This hook keeps `:stale?` instead, and it reads the list on the
  way out of standby.

  A read on the way back is one read, whatever the number of events that arrived, and
  it clears the mark before it asks, so a second event of one wake asks for nothing.

  ## Why hooks and not a `use` macro

  A macro writes its clauses where the `use` stands, and a page writes clauses of
  `handle_event/3` and `handle_info/2` of its own. The compiler then reports that the
  clauses of one function are not together, and `mix check` treats that as an error.
  `Phoenix.LiveView.attach_hook/4` adds a clause that runs before the page, and it makes
  no such trouble. `PiFiWeb.BrowseLive` writes out the clause of `Cinder.UrlSync` for
  the same reason.

  ## What a page must hold

  `:source` names the source that the rows belong to, and `:collection_id` names the
  collection that a mark refreshes. A page that draws no collection sets `nil` there,
  and this hook then reads nothing.

  `:opened` is the container that a person is inside, and a page that is inside none
  is `nil`. A mark on that container reads it again, so the head of it draws the
  star that the person just pressed.
  """

  use PiFiWeb, :html

  alias PiFi.Artwork
  alias PiFi.Event
  alias PiFi.Event.Player, as: Events
  alias PiFi.Playback
  alias PiFi.Playback.Item

  import Phoenix.LiveView,
    only: [attach_hook: 4, connected?: 1, put_flash: 3]

  require Ash.Query

  # The list that a person is looking at goes in the queue, so next and previous move
  # through what they see. A longer list than this is more than a person steps through,
  # and the whole of a country would be a read of every row of it.
  @queue_limit 500

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Event.subscribe(:source)

    socket =
      socket
      |> Phoenix.Component.assign(:playing, playing(Playback.state!()))
      |> Phoenix.Component.assign(:reading, %{})
      |> Phoenix.Component.assign(:stale?, false)
      |> Phoenix.Component.assign(:adding, nil)
      |> Phoenix.Component.assign(:playlists, [])
      |> attach_hook(:item_list_events, :handle_event, &event/3)
      |> attach_hook(:item_list_info, :handle_info, &info/2)

    {:cont, socket}
  end

  @doc """
  The rows whose title carries the text of a person, in any case.

  Cinder gives the columns that hold `search` and the text that a person typed. This
  is the `fn` of the `search` of `Cinder.collection`, and `filter_title/2` is the one
  of the text filter of a column. Both read the same expression, so a person who finds
  a station on the search page finds it under a filter as well.

  ## It matches the start of a word, and not a text in the middle of one

  The match reads `playback_items_fts`, which is the FTS5 index of the titles that
  `PiFi.Repo.Migrations.SearchTheWordsOfATitle` makes. **A person who types `cell`
  therefore finds `Celldweller` and does not find `Excellent`.** That is the trade, and
  it is deliberate: the start of a word is what a person means almost every time, and
  the expression before this one read every row of the table. A search for a common
  word over 137,557 items took 4.74 s on a board on 2026-09-16.

  **Each word of the text matches separately, and a row must carry all of them.** A
  person who types `rnz nat` finds `RNZ National`. The last word takes no `*` of its
  own beyond the one that `fts_match/1` adds, so a search narrows as a person types.

  ## Why the matching is ours and not the one that Cinder gives

  Cinder wraps the text in an `Ash.CiString` and asks for `contains`. On AshSqlite that
  compiles to `instr(title, ? COLLATE NOCASE)`, and `instr` of SQLite reads no
  collation, so it matches the case. A person who types `rnz` would find no
  `RNZ National`. FTS5 folds the case itself, with the `unicode61` tokenizer.
  """
  @spec search_title(Ash.Query.t(), [term()], String.t()) :: Ash.Query.t()
  def search_title(query, _columns, text), do: matching(query, text)

  @doc """
  The rows of a text filter of Cinder, which carries the text and the way to match it.

  Cinder keeps one filter for each column, and it passes the whole filter here.
  `contains` is the operator that a column of this firmware asks for, and it is the
  one that this reads: a column that asked for another one would need another
  expression, and this raises rather than match the wrong rows. See `search_title/3`
  for why the expression is ours.
  """
  @spec filter_title(Ash.Query.t(), map()) :: Ash.Query.t()
  def filter_title(query, %{operator: :contains, value: text}), do: matching(query, text)

  # **A text that holds no word matches every row.** A person who clears the box reads
  # the whole list again, and `MATCH` of FTS5 raises on an empty query, so the filter
  # goes away instead.
  defp matching(query, text) do
    case fts_match(text) do
      nil ->
        query

      match ->
        # **The index takes no alias, and the identifier takes the cast that Ash gives
        # it.** `MATCH` reads the name of the table on its left, and an alias there is
        # a column that does not exist. Ash writes `CAST(id AS TEXT)` on the outer
        # side, so the inner side casts as well or the two never match.
        Ash.Query.filter(
          query,
          fragment(
            """
            ? IN (SELECT CAST(i.id AS TEXT) FROM playback_items AS i
                  JOIN playback_items_fts ON i.rowid = playback_items_fts.rowid
                  WHERE playback_items_fts MATCH ?)
            """,
            id,
            ^match
          )
        )
    end
  end

  @doc """
  The text of a person as a query of FTS5, or `nil` when it holds no word.

  **Every word is quoted, and every word takes a `*`.** A quote makes each word a
  string that FTS5 reads as it is, so `AND`, `OR`, `NOT` and `-` are words and not
  operators, and a person who searches for `rock and roll` is not asking a question of
  the parser. The `*` sits outside the quotes, where FTS5 reads it as "the start of a
  word", so `cell` finds `Celldweller`.

  A quote inside a word is doubled, which is how FTS5 escapes one.

      iex> PiFiWeb.ItemList.fts_match("rnz nat")
      "\\"rnz\\"* \\"nat\\"*"

      iex> PiFiWeb.ItemList.fts_match("  ")
      nil

      iex> PiFiWeb.ItemList.fts_match(nil)
      nil

      iex> PiFiWeb.ItemList.fts_match("say \\"hello\\"")
      "\\"say\\"* \\"\\"\\"hello\\"\\"\\"*"
  """
  @spec fts_match(String.t() | nil) :: String.t() | nil
  def fts_match(nil), do: nil

  def fts_match(text) do
    case String.split(text, ~r/\s+/u, trim: true) do
      [] -> nil
      words -> Enum.map_join(words, " ", &prefix_phrase/1)
    end
  end

  defp prefix_phrase(word), do: ~s("#{String.replace(word, ~s("), ~s(""))}"*)

  attr :path, :string, default: nil
  attr :class, :string, default: "size-8"
  attr :icon_class, :string, default: "size-4"

  @doc """
  The picture of a container, with a folder behind it.

  **The folder is not a choice of the caller, and the picture is not certain.**
  `PiFi.Artwork.thumbnail_path/1` builds the address without reading the cache, so a
  list costs no query to draw and no row knows whether its picture is there. A picture
  that the cache does not hold answers 404, the browser takes the image away, and the
  folder behind it stays.

  `loading="lazy"` is what keeps the cost down on a long list: a browser asks for the
  rows that a person can see, and not for the hundred of a page.

  `data-cover` is what `assets/js/cover.js` reads to take a broken picture away. **An
  `onerror` attribute cannot do it**, because the content security policy of
  `PiFiWeb.Router` names no `script-src` and therefore takes `'self'`, which blocks
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
  attr :number?, :boolean, default: false
  attr :facts, :list, default: []
  attr :reading, :map, default: %{}

  @doc """
  One row of a list.

  A facet opens and never plays. An item opens when it is a container, and it plays when
  it is a track.

  **The source says what a row draws beside its title**, and this module draws
  each fact. See `c:PiFi.Source.listing/1`. A row of an album reads

      1-01 · Original Bedroom Rockers · Kruder & Dorfmeister · 6:07

  and a row of a show reads

      639 · 24 August · Uncle Silicon · 44m left

  A fact that this module does not know draws nothing, so a source that names a new one
  reaches a screen when that screen learns it, and never as an error.
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
        <span class="min-w-0 grow">
          <span class="block truncate text-ink group-hover:text-accent">{@row.title}</span>
          <.facts :if={@facts != []} row={@row} facts={@facts} />
        </span>
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
        <.play_mark status={@status} />

        <span :if={@number? and place_text(@row)} class="numerals w-9 shrink-0 text-right text-xs text-ink-faint">
          {place_text(@row)}
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
          <.facts :if={@facts != []} row={@row} facts={@facts} />
          <span
            :if={@facts == [] and @row.subtitle}
            class="block truncate text-xs text-ink-faint"
          >
            {@row.subtitle}
          </span>
        </span>

        <.audio_mark row={@row} reading={@reading} />
      </button>
      <.add_to_queue row={@row} />
      <.played row={@row} />
      <.favourite row={@row} />
    </div>
    """
  end

  attr :status, :atom, required: true

  @doc """
  What the play control shows: a meter, a pause, a spinner, or a play mark.

  `row/1`, `play_cell/1` and `card/1` all draw it, so the three views cannot disagree
  about what a state looks like.
  """
  def play_mark(assigns) do
    ~H"""
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
    """
  end

  attr :row, :any, required: true
  attr :kind, :atom, required: true
  attr :playing, :any, required: true
  attr :source, :any, required: true

  @doc """
  The control that plays one row, for a cell of a table.

  It is the button that `row/1` draws at the head of a row, and nothing else, so the
  two views press the same event and read the same state.
  """
  def play_cell(%{kind: :facet} = assigns) do
    ~H"""
    <span class="flex size-8 items-center justify-center text-ink-faint">
      <.icon name="hero-folder" class="size-4" />
    </span>
    """
  end

  def play_cell(assigns) do
    assigns = assign(assigns, :status, status_of(assigns.playing, assigns.source, assigns.row))

    ~H"""
    <button
      type="button"
      id={"play-#{@row.id}"}
      phx-click="play"
      phx-value-id={@row.id}
      aria-current={@status && "true"}
      aria-label={"Play #{@row.title}"}
      class="group flex items-center"
    >
      <.play_mark status={@status} />
    </button>
    """
  end

  attr :row, :any, required: true
  attr :kind, :atom, required: true
  attr :number?, :boolean, required: true

  @doc "The place of one row inside its container, for a cell of a table."
  def place_cell(%{kind: :facet} = assigns) do
    ~H"""
    <span :if={@row} />
    """
  end

  def place_cell(assigns) do
    ~H"""
    <span :if={@number? and place_text(@row)} class="numerals text-xs text-ink-faint">
      {place_text(@row)}
    </span>
    """
  end

  attr :row, :any, required: true
  attr :kind, :atom, required: true
  attr :facts, :list, required: true

  @doc """
  The title of one row and the facts under it, for a cell of a table.

  A container is a link into itself, and a track is not: pressing a track plays it, and
  that control is a cell of its own.
  """
  def title_cell(%{kind: :facet} = assigns) do
    ~H"""
    <button type="button" id={"open-#{@row.id}"} phx-click="open" phx-value-id={@row.id}>
      <span class="truncate text-ink hover:text-accent">{to_string(@row.value.value)}</span>
    </button>
    """
  end

  def title_cell(%{row: %Item{kind: :container}} = assigns) do
    assigns = assign(assigns, :artwork, Artwork.thumbnail_path(Map.get(assigns.row, :artwork)))

    ~H"""
    <button
      type="button"
      id={"open-#{@row.id}"}
      phx-click="open"
      phx-value-id={@row.id}
      class="group flex min-w-0 items-center gap-3 text-left"
    >
      <.cover path={@artwork} class="size-8" />
      <span class="min-w-0">
        <span class="block truncate text-ink group-hover:text-accent">{@row.title}</span>
        <.facts :if={@facts != []} row={@row} facts={@facts} />
      </span>
      <.count of={@row.child_count} />
    </button>
    """
  end

  def title_cell(assigns) do
    ~H"""
    <span class="block min-w-0">
      <span class="block truncate text-ink">{@row.title}</span>
      <.facts :if={@facts != []} row={@row} facts={@facts} />
      <span :if={@facts == [] and @row.subtitle} class="block truncate text-xs text-ink-faint">
        {@row.subtitle}
      </span>
    </span>
    """
  end

  attr :row, :any, required: true
  attr :kind, :atom, required: true
  attr :playing, :any, required: true
  attr :source, :any, required: true
  attr :facts, :list, required: true
  attr :reading, :map, required: true

  @doc """
  One row as a card, with the picture above the words.

  **A card is for the picture**, so the cover fills the width of it and the title sits
  under. A person who reads a shelf of albums recognises a cover before they read a
  title, which is the reason to offer this view at all.

  Pressing a card does what pressing the row does: it opens a container and it plays a
  track.
  """
  def card(%{kind: :facet} = assigns) do
    ~H"""
    <button
      type="button"
      id={"open-#{@row.id}"}
      phx-click="open"
      phx-value-id={@row.id}
      class="group flex w-full flex-col gap-2 text-left"
    >
      <.cover class="aspect-square w-full" icon_class="size-8" />
      <span class="min-w-0">
        <span class="block truncate text-sm text-ink group-hover:text-accent">
          {to_string(@row.value.value)}
        </span>
        <.count of={@row.item_count} />
      </span>
    </button>
    """
  end

  def card(assigns) do
    assigns =
      assigns
      |> assign(:status, status_of(assigns.playing, assigns.source, assigns.row))
      |> assign(:artwork, Artwork.thumbnail_path(Map.get(assigns.row, :artwork)))
      |> assign(:container?, assigns.row.kind == :container)

    ~H"""
    <div class="flex w-full min-w-0 flex-col gap-2">
      <button
        type="button"
        id={"#{if @container?, do: "open", else: "play"}-#{@row.id}"}
        phx-click={if @container?, do: "open", else: "play"}
        phx-value-id={@row.id}
        aria-current={@status && "true"}
        aria-label={"#{if @container?, do: "Open", else: "Play"} #{@row.title}"}
        class="group relative flex w-full flex-col gap-2 text-left"
      >
        <.cover path={@artwork} class="aspect-square w-full" icon_class="size-8" />

        <span
          :if={@status}
          class="absolute left-1 top-1 rounded-full bg-shell/70 p-0.5"
          aria-hidden="true"
        >
          <.play_mark status={@status} />
        </span>

        <span class="min-w-0">
          <span class={[
            "block truncate text-sm",
            if(@status, do: "font-medium text-accent", else: "text-ink group-hover:text-accent")
          ]}>
            {@row.title}
          </span>
          <.facts :if={@facts != []} row={@row} facts={@facts} />
          <span
            :if={@facts == [] and @row.subtitle}
            class="block truncate text-xs text-ink-faint"
          >
            {@row.subtitle}
          </span>
        </span>
      </button>

      <span class="flex items-center gap-1">
        <.audio_mark row={@row} reading={@reading} />
        <span class="grow" />
        <.add_to_queue row={@row} />
        <.played row={@row} />
        <.favourite row={@row} />
      </span>
    </div>
    """
  end

  attr :row, :any, required: true
  attr :kind, :atom, required: true
  attr :reading, :map, required: true

  @doc """
  What a person can do with one row, for a cell of a table.

  **A facet is a way into a list and not a thing.** A person cannot play a country, mark
  it, or put it in the queue, so its row draws the count and nothing else.
  """
  def controls_cell(%{kind: :facet} = assigns) do
    ~H"""
    <span class="flex items-center justify-end">
      <.count of={@row.item_count} />
    </span>
    """
  end

  def controls_cell(assigns) do
    ~H"""
    <span class="flex items-center justify-end gap-1">
      <.audio_mark row={@row} reading={@reading} />
      <.add_to_queue row={@row} />
      <.add_to_playlist row={@row} />
      <.played row={@row} />
      <.favourite row={@row} />
    </span>
    """
  end

  attr :row, :any, required: true

  # **A container has no audio of its own, so it goes in no queue.** A person adds an
  # album by the control at the head of it, which takes every track of the list.
  defp add_to_queue(assigns) do
    ~H"""
    <button
      :if={@row.kind != :container}
      type="button"
      id={"queue-#{@row.id}"}
      phx-click="queue"
      phx-value-id={@row.id}
      aria-label={"Add #{@row.title} to the queue"}
      class="flex size-9 shrink-0 items-center justify-center rounded-full text-ink-faint hover:text-ink"
    >
      <.icon name="hero-plus" class="size-5" />
    </button>
    """
  end

  attr :row, :any, required: true

  # A container has no audio of its own, and a playlist carries tracks, so a person
  # adds the tracks of an album one at a time or keeps the queue. See
  # `PiFiWeb.PlaylistLive`.
  defp add_to_playlist(assigns) do
    ~H"""
    <button
      :if={@row.kind != :container}
      type="button"
      id={"playlist-#{@row.id}"}
      phx-click="add_to_playlist"
      phx-value-id={@row.id}
      aria-label={"Put #{@row.title} in a playlist"}
      class="flex size-9 shrink-0 items-center justify-center rounded-full text-ink-faint hover:text-ink"
    >
      <.icon name="hero-list-bullet" class="size-5" />
    </button>
    """
  end

  attr :adding, :any, required: true
  attr :playlists, :list, required: true

  @doc """
  The panel that asks which playlist a track goes in.

  **One panel for the whole page, and not one for each row.** A list draws 25 rows and
  a menu inside each one would be 25 copies of the same names. `:adding` carries the
  track that a person pressed, and this draws nothing while it is `nil`.

  A page that draws a list therefore draws this one time. See `PiFiWeb.BrowseLive`.
  """
  def playlist_sheet(assigns) do
    ~H"""
    <div
      :if={@adding}
      id="playlist-sheet"
      class="glass sheen fixed inset-x-3 bottom-24 z-50 mx-auto max-w-md rounded-xl p-4 sm:inset-x-5"
    >
      <div class="mb-3 flex items-center gap-2">
        <h2 class="grow text-xs uppercase tracking-[0.18em] text-ink-faint">Put this in</h2>

        <button
          type="button"
          id="cancel-add"
          phx-click="cancel_add"
          aria-label="Leave this"
          class="control rounded-lg p-1.5"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <ul :if={@playlists != []} class="mb-3 divide-y divide-edge">
        <li :for={playlist <- @playlists}>
          <button
            type="button"
            id={"add-here-#{playlist.id}"}
            phx-click="add_here"
            phx-value-playlist={playlist.id}
            class="flex w-full items-center gap-3 py-2 text-left hover:text-accent"
          >
            <.icon name="hero-list-bullet" class="size-5 shrink-0 text-ink-faint" />
            <span class="min-w-0 grow truncate text-ink">{playlist.name}</span>
          </button>
        </li>
      </ul>

      <form id="add-to-new-form" phx-submit="add_to_new" class="flex items-center gap-2">
        <input
          type="text"
          id="new-playlist-name"
          name="name"
          maxlength="100"
          required
          autocomplete="off"
          placeholder="A new playlist"
          aria-label="The name of a new playlist"
          class="control grow rounded-lg px-3 py-2 text-sm"
        />
        <button type="submit" id="add-to-new" class="control rounded-lg px-3 py-2 text-sm">
          Make it
        </button>
      </form>
    </div>
    """
  end

  attr :row, :any, required: true
  attr :reading, :map, required: true

  # **How much of the audio of one row this device keeps.** A person reads it to know what
  # plays with no network, and a file that is arriving says how far it has come.
  defp audio_mark(assigns) do
    assigns = assign(assigns, :audio, audio(assigns.reading, assigns.row))

    ~H"""
    <span :if={@audio} class="flex shrink-0 items-center gap-1 text-xs text-ink-faint">
      <span :if={@audio != :held} class="numerals">{@audio}</span>
      <.icon :if={@audio == :held} name="hero-arrow-down-tray-mini" class="size-4" />
      <span :if={@audio == :held} class="sr-only">On the card</span>
      <.icon
        :if={@audio != :held}
        name="hero-arrow-path-mini"
        class="size-4 motion-safe:animate-spin"
      />
    </span>
    """
  end

  @doc """
  What a row says about the audio of its item.

  It returns `:held` for a file that the card holds, a share such as `"42%"` for one that
  is arriving, and `nil` for an item that this device does not hold.

  **The map wins over the row.** `audio_held?` of the row is what the read that drew the
  list found, and a file that arrived after that read reaches the map alone. See
  `PiFi.Event.Source.AudioChanged`.

      iex> PiFiWeb.ItemList.audio(%{}, %{id: "a", audio_held?: true})
      :held

      iex> PiFiWeb.ItemList.audio(%{"a" => :held}, %{id: "a", audio_held?: false})
      :held

      iex> PiFiWeb.ItemList.audio(%{"a" => {:reading, 500}}, %{id: "a", byte_size: 1000})
      "50%"

      iex> PiFiWeb.ItemList.audio(%{}, %{id: "a", audio_held?: false})
      nil
  """
  @spec audio(map(), map()) :: :held | String.t() | nil
  def audio(reading, %{id: id} = row) do
    case Map.get(reading, id) do
      :held -> :held
      {:reading, bytes} -> share(bytes, row)
      :absent -> nil
      nil -> if held?(row), do: :held
    end
  end

  # A row that named no calculation carries `%Ash.NotLoaded{}`, and a list that draws no
  # such mark must not fail for it.
  defp held?(%{audio_held?: true}), do: true
  defp held?(_row), do: false

  # **A share needs the size of the file, and the item carries it.** A source that names
  # none leaves a person with a mark that turns and no number, which still says that the
  # device is reading it.
  defp share(bytes, %{byte_size: total}) when is_integer(total) and total > 0 do
    "#{min(round(bytes / total * 100), 100)}%"
  end

  defp share(_bytes, _row), do: "Reading"

  attr :row, :any, required: true
  attr :facts, :list, required: true

  # A row draws its facts on one line, and a fact that says nothing takes no room and no
  # separator with it.
  defp facts(assigns) do
    assigns = assign(assigns, :drawn, Enum.map(assigns.facts, &fact(&1, assigns.row)))

    ~H"""
    <span class="block truncate text-xs text-ink-faint">
      {@drawn |> Enum.reject(&is_nil/1) |> Enum.join(" · ")}
    </span>
    """
  end

  @doc """
  The place of one item inside its container, for a person to read.

  It returns `nil` for an item with no place. `place` of `PiFi.Playback.Item` is
  the same fact as one number, which is what a list sorts on.

  A set of more than one disc names the disc, because track 1 of disc 2 comes after
  track 12 of disc 1 and the number alone cannot say that.

      iex> PiFi.Playback.Item |> struct(number: 1, disc: 1) |> PiFiWeb.ItemList.place_text()
      "1-01"

      iex> PiFi.Playback.Item |> struct(number: 639) |> PiFiWeb.ItemList.place_text()
      "639"

      iex> PiFi.Playback.Item |> struct(%{}) |> PiFiWeb.ItemList.place_text()
      nil
  """
  @spec place_text(map()) :: String.t() | nil
  def place_text(%{disc: disc, number: number}) when is_integer(disc) and is_integer(number) do
    "#{disc}-#{String.pad_leading(to_string(number), 2, "0")}"
  end

  def place_text(%{number: number}) when is_integer(number), do: to_string(number)

  def place_text(_row), do: nil

  @doc """
  One fact of a row, as a person reads it.

  Each name is a field of `PiFi.Playback.Item`, and `{:text, "…"}` says something
  that no field carries. A fact of no value returns `nil`, and the row then draws neither
  it nor a separator for it.

      iex> PiFiWeb.ItemList.fact(:duration_ms, %{duration_ms: 367_000})
      "6:07"

      iex> PiFiWeb.ItemList.fact({:text, "128 kbit/s"}, %{})
      "128 kbit/s"
  """
  @spec fact(PiFi.Source.fact(), map()) :: String.t() | nil
  def fact({:text, text}, _row), do: text

  def fact(:subtitle, %{subtitle: subtitle}), do: subtitle

  def fact(:release_year, %{release_year: year}) when is_integer(year) and year > 0,
    do: to_string(year)

  def fact(:published_at, %{published_at: %DateTime{} = at}), do: day(at)

  def fact(:duration_ms, %{duration_ms: ms}) when is_integer(ms) and ms > 0, do: clock(ms)

  # **An episode that no person began reads as a length and not as a time left.**
  # `remaining_ms` is the whole duration of such an item, because `position_ms` begins
  # at 0, and "1h 2m left" of an episode that nobody touched says the wrong thing.
  def fact(:remaining_ms, %{played?: true}), do: "Played"

  def fact(:remaining_ms, %{remaining_ms: ms, duration_ms: ms}) when is_integer(ms),
    do: clock(ms)

  def fact(:remaining_ms, %{remaining_ms: ms}) when is_integer(ms) and ms > 0,
    do: "#{minutes(ms)} left"

  def fact(_name, _row), do: nil

  # The day and the month, and the year of a date of another year. A person reads a
  # podcast of this week and the year says nothing, and an album of 2013 needs it.
  defp day(at) do
    if at.year == DateTime.utc_now().year do
      Calendar.strftime(at, "%-d %B")
    else
      Calendar.strftime(at, "%-d %B %Y")
    end
  end

  defp clock(milliseconds) do
    seconds = div(milliseconds, 1000)
    minutes = div(seconds, 60)

    case div(minutes, 60) do
      0 -> "#{minutes}:#{pad(rem(seconds, 60))}"
      hours -> "#{hours}:#{pad(rem(minutes, 60))}:#{pad(rem(seconds, 60))}"
    end
  end

  # A time left is a round number, because a person reads it to decide whether they
  # have time for the rest of an episode.
  defp minutes(milliseconds) do
    case div(milliseconds, 60_000) do
      minutes when minutes < 60 -> "#{minutes}m"
      minutes when rem(minutes, 60) == 0 -> "#{div(minutes, 60)}h"
      minutes -> "#{div(minutes, 60)}h #{rem(minutes, 60)}m"
    end
  end

  defp pad(seconds), do: String.pad_leading(to_string(seconds), 2, "0")

  attr :of, :integer, required: true

  @doc """
  How many rows a container contains.

  It tells a person whether the row is worth opening. An empty container
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

  # A station is a track that a person marks, and a show is a container that they
  # subscribe to. One control serves both, and an episode carries no mark of its own.
  @doc """
  The control that marks one item, or takes the mark away.

  **A row draws it and so does the head of a collection.** A person who opened an album
  and liked what they read marks it there, and they do not walk back up the tree to
  reach the row that names it. See `PiFiWeb.BrowseLive`.

  An episode draws none. An episode belongs to a show and a person marks the show, so
  `markable?/1` answers for the kind of the item and not for the page that draws it.
  """
  attr :row, :any, required: true

  def favourite(assigns) do
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

  @doc """
  The control that says that a person is done with a track, or takes that back.

  **A track that keeps its place draws it, and no other row does.** An episode of a
  show and a chapter of an audiobook are the tracks that a person hears over several
  days, so they are the tracks that a person leaves unfinished. A song has no place at
  all, and a station has none either. See `keeps_place?` of
  `PiFi.Playback.Item`.

  A track that reaches its end takes the same mark from `PiFi.Player`, so this
  control says what the end of the track says. The row of a marked episode reads
  "Played" in the place of the time that is left.
  """
  attr :row, :any, required: true

  def played(assigns) do
    ~H"""
    <button
      :if={@row.keeps_place?}
      type="button"
      id={"played-#{@row.id}"}
      phx-click="played"
      phx-value-id={@row.id}
      aria-pressed={to_string(@row.played? == true)}
      aria-label="Played"
      class={[
        "flex size-9 shrink-0 items-center justify-center rounded-full",
        if(@row.played?, do: "text-accent", else: "text-ink-faint hover:text-ink")
      ]}
    >
      <.icon
        name={if @row.played?, do: "hero-check-circle-solid", else: "hero-check-circle"}
        class="size-5"
      />
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
  # see it. `:list_query` carries the sort and the filters that Cinder read, so a person
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

  # **Adding to the queue plays nothing and changes nothing that is playing.** A person
  # who presses this wants to hear the track after what is on now, so the row goes on
  # the end of the queue and the player carries on. It takes the one row that they
  # pressed, and not the list around it: they chose a track, not a list.
  defp event("queue", %{"id" => id}, socket) do
    with {:ok, item} <- Playback.get_item(id),
         {:ok, _rows} <- Playback.append_to_queue([id]) do
      {:halt, put_flash(socket, :info, "#{item.title} is next in the queue.")}
    else
      {:error, reason} ->
        {:halt, put_flash(socket, :error, "Could not add that to the queue: #{inspect(reason)}")}
    end
  end

  # The list that a person sees is what goes on the end, in the order that they see it,
  # which is the rule that `play_collection` follows.
  defp event("queue_collection", _params, socket) do
    case queue_ids(socket, nil) do
      [] ->
        {:halt, put_flash(socket, :error, "There is nothing here to add.")}

      ids ->
        case Playback.append_to_queue(ids) do
          {:ok, _rows} ->
            {:halt, put_flash(socket, :info, "#{length(ids)} tracks are in the queue.")}

          {:error, reason} ->
            {:halt,
             put_flash(socket, :error, "Could not add those to the queue: #{inspect(reason)}")}
        end
    end
  end

  defp event("favourite", %{"id" => id}, socket) do
    with {:ok, item} <- Playback.get_item(id),
         {:ok, marked} <- mark(item) do
      {:halt, socket |> opened(marked) |> read_again()}
    else
      {:error, reason} ->
        {:halt, put_flash(socket, :error, "Could not do that: #{inspect(reason)}")}
    end
  end

  # A marked row draws "Played" in the place of the time that is left, so the list
  # reads itself again and a person sees both the control and the fact.
  defp event("played", %{"id" => id}, socket) do
    with {:ok, item} <- Playback.get_item(id),
         {:ok, _marked} <- mark_played(item) do
      {:halt, read_again(socket)}
    else
      {:error, reason} ->
        {:halt, put_flash(socket, :error, "Could not do that: #{inspect(reason)}")}
    end
  end

  # **The panel reads the playlists one time, when it opens.** A person who presses
  # this asks a question, and the answer is a list of a few names. A page that read
  # them on each render would read them for every event of the player.
  defp event("add_to_playlist", %{"id" => id}, socket) do
    {:halt,
     socket
     |> Phoenix.Component.assign(:adding, id)
     |> Phoenix.Component.assign(:playlists, Playback.list_playlists!())}
  end

  defp event("cancel_add", _params, socket) do
    {:halt, Phoenix.Component.assign(socket, :adding, nil)}
  end

  defp event("add_here", %{"playlist" => playlist_id}, socket) do
    with {:ok, playlist} <- Playback.get_playlist(playlist_id),
         {:ok, item} <- Playback.get_item(socket.assigns.adding),
         {:ok, _entries} <- Playback.add_to_playlist(playlist.id, [item.id]) do
      {:halt,
       socket
       |> Phoenix.Component.assign(:adding, nil)
       |> put_flash(:info, "#{item.title} is in #{playlist.name}.")}
    else
      {:error, reason} ->
        {:halt,
         socket
         |> Phoenix.Component.assign(:adding, nil)
         |> put_flash(:error, "Could not do that: #{inspect(reason)}")}
    end
  end

  defp event("add_to_new", %{"name" => name}, socket) do
    with {:ok, playlist} <- Playback.create_playlist(name),
         {:ok, item} <- Playback.get_item(socket.assigns.adding),
         {:ok, _entries} <- Playback.add_to_playlist(playlist.id, [item.id]) do
      {:halt,
       socket
       |> Phoenix.Component.assign(:adding, nil)
       |> put_flash(:info, "#{playlist.name} has #{item.title}.")}
    else
      {:error, _reason} ->
        {:halt,
         put_flash(
           socket,
           :error,
           "Another playlist has that name, or the name is empty."
         )}
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
  # it, and a page keeps that in `:list_query`. A page with none, such as the
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

  # **A row draws what the card keeps, and this holds that state in memory.** The read
  # that drew the list gave `audio_held?` of each row, and a file that arrives after it
  # would need a whole read of the list to show. This map keeps what moved since, so a
  # row that was empty fills while a person watches and no query runs for it. See
  # `PiFi.Event.Source.AudioChanged`.
  defp info(%Event.Source.AudioChanged{state: :reading} = event, socket) do
    reading = Map.put(socket.assigns.reading, event.item_id, {:reading, event.bytes})

    {:halt, Phoenix.Component.assign(socket, :reading, reading)}
  end

  defp info(%Event.Source.AudioChanged{state: state} = event, socket) do
    reading = Map.put(socket.assigns.reading, event.item_id, state)

    {:halt, Phoenix.Component.assign(socket, :reading, reading)}
  end

  # A device in standby draws no list, so this keeps the mark and reads nothing. See the
  # module documentation.
  defp info(%Event.Source.Changed{}, %{assigns: %{standby?: true}} = socket) do
    {:halt, Phoenix.Component.assign(socket, :stale?, true)}
  end

  defp info(%Event.Source.Changed{}, socket), do: {:halt, read_again(socket)}

  # `PiFiWeb.Shell` receives this event as well, and it passes it on, so the value of
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

  # **A mark on the container that a person is inside redraws the head of it.** The
  # control of that head marks the same item as a row does, and the page keeps the item
  # of it in an assign, so a mark that changed nothing there would draw a star that is
  # empty on a container that a person just marked.
  defp opened(%{assigns: %{opened: %{id: id}}} = socket, %{id: id} = marked) do
    Phoenix.Component.assign(socket, :opened, Ash.load!(marked, :artwork))
  end

  defp opened(socket, _marked), do: socket

  # A page that draws no collection has no identifier, and `PiFiWeb.BrowseLive`
  # draws none while it says that this firmware knows no source.
  defp read_again(socket) do
    case socket.assigns[:collection_id] do
      nil -> socket
      collection_id -> Cinder.Refresh.refresh_table(socket, collection_id)
    end
  end

  defp mark(%{favourite?: true} = item), do: Playback.clear_favourite(item)
  defp mark(item), do: Playback.set_favourite(item)

  defp mark_played(%{played?: true} = item), do: Playback.clear_played(item)
  defp mark_played(item), do: Playback.mark_played(item)

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
