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

  `on_mount/1` subscribes to the sources, assigns `:playing`, and answers the `play`,
  the `favourite` and the `played` events and every event of the player. A page
  therefore holds none of that.

  **`MyHiFiWeb.Shell` holds the subscription to the `:player` topic**, and this hook
  takes it again for nothing: two subscriptions of one process give two copies of each
  event, and a page then reads a `MyHiFi.Event.Player.Progress` twice each second. A
  hook reads every message of the process that it runs in, whichever part asked for the
  topic, so the clauses below need no subscription of their own.

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

  `:opened` is the container that a person is inside, and a page that is inside none
  holds `nil`. A mark on that container reads it again, so the head of it draws the
  star that the person just pressed.
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
    if connected?(socket), do: Event.subscribe(:source)

    socket =
      socket
      |> Phoenix.Component.assign(:playing, playing(Playback.state!()))
      |> Phoenix.Component.assign(:reading, %{})
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
  attr :number?, :boolean, default: false
  attr :facts, :list, default: []
  attr :reading, :map, default: %{}

  @doc """
  One row of a list.

  A facet opens and never plays. An item opens when it is a container, and it plays when
  it is a track.

  **The source says what a row draws beside its title**, and this holds the drawing of
  each fact. See `c:MyHiFi.Source.listing/1`. A row of an album reads

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
      <.played row={@row} />
      <.favourite row={@row} />
    </div>
    """
  end

  attr :row, :any, required: true
  attr :reading, :map, required: true

  # **What this device holds of the audio of one row.** A person reads it to know what
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

  It gives `:held` for a file that the card holds, a share such as `"42%"` for one that
  is arriving, and `nil` for an item that this device does not hold.

  **The map wins over the row.** `audio_held?` of the row is what the read that drew the
  list found, and a file that arrived after that read reaches the map alone. See
  `MyHiFi.Event.Source.AudioChanged`.

      iex> MyHiFiWeb.ItemList.audio(%{}, %{id: "a", audio_held?: true})
      :held

      iex> MyHiFiWeb.ItemList.audio(%{"a" => :held}, %{id: "a", audio_held?: false})
      :held

      iex> MyHiFiWeb.ItemList.audio(%{"a" => {:reading, 500}}, %{id: "a", byte_size: 1000})
      "50%"

      iex> MyHiFiWeb.ItemList.audio(%{}, %{id: "a", audio_held?: false})
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

  # A row that named no calculation holds `%Ash.NotLoaded{}`, and a list that draws no
  # such mark must not fail for it.
  defp held?(%{audio_held?: true}), do: true
  defp held?(_row), do: false

  # **A share needs the size of the file, and the item holds it.** A source that names
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

  It gives `nil` for an item that holds no place. `place` of `MyHiFi.Playback.Item` is
  the same fact as one number, which is what a list sorts on.

  A set of more than one disc names the disc, because track 1 of disc 2 comes after
  track 12 of disc 1 and the number alone cannot say that.

      iex> MyHiFi.Playback.Item |> struct(number: 1, disc: 1) |> MyHiFiWeb.ItemList.place_text()
      "1-01"

      iex> MyHiFi.Playback.Item |> struct(number: 639) |> MyHiFiWeb.ItemList.place_text()
      "639"

      iex> MyHiFi.Playback.Item |> struct(%{}) |> MyHiFiWeb.ItemList.place_text()
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

  Each name is a field of `MyHiFi.Playback.Item`, and `{:text, "…"}` says something
  that no field holds. A fact of no value gives `nil`, and the row then draws neither
  it nor a separator for it.

      iex> MyHiFiWeb.ItemList.fact(:duration_ms, %{duration_ms: 367_000})
      "6:07"

      iex> MyHiFiWeb.ItemList.fact({:text, "128 kbit/s"}, %{})
      "128 kbit/s"
  """
  @spec fact(MyHiFi.Source.fact(), map()) :: String.t() | nil
  def fact({:text, text}, _row), do: text

  def fact(:subtitle, %{subtitle: subtitle}), do: subtitle

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

  # A station is a track that a person marks, and a show is a container that they
  # subscribe to. One control serves both, and an episode carries no mark of its own.
  @doc """
  The control that marks one item, or takes the mark away.

  **A row draws it and so does the head of a collection.** A person who opened an album
  and liked what they read marks it there, and they do not walk back up the tree to
  reach the row that names it. See `MyHiFiWeb.BrowseLive`.

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
  days, so they are the tracks that a person leaves unfinished. A song holds no place
  at all, and a station holds none either. See `keeps_place?` of
  `MyHiFi.Playback.Item`.

  A track that reaches its end takes the same mark from `MyHiFi.Player`, so this
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

  # **A row draws what the card holds, and this keeps that state in memory.** The read
  # that drew the list gave `audio_held?` of each row, and a file that arrives after it
  # would need a whole read of the list to show. This map holds what moved since, so a
  # row that was empty fills while a person watches and no query runs for it. See
  # `MyHiFi.Event.Source.AudioChanged`.
  defp info(%Event.Source.AudioChanged{state: :reading} = event, socket) do
    reading = Map.put(socket.assigns.reading, event.item_id, {:reading, event.bytes})

    {:halt, Phoenix.Component.assign(socket, :reading, reading)}
  end

  defp info(%Event.Source.AudioChanged{state: state} = event, socket) do
    reading = Map.put(socket.assigns.reading, event.item_id, state)

    {:halt, Phoenix.Component.assign(socket, :reading, reading)}
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

  # **A mark on the container that a person is inside redraws the head of it.** The
  # control of that head marks the same item as a row does, and the page holds the item
  # of it in an assign, so a mark that changed nothing there would draw a star that is
  # empty on a container that a person just marked.
  defp opened(%{assigns: %{opened: %{id: id}}} = socket, %{id: id} = marked) do
    Phoenix.Component.assign(socket, :opened, Ash.load!(marked, :artwork))
  end

  defp opened(socket, _marked), do: socket

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
