defmodule PiFiWeb.PlayerLive do
  @moduledoc """
  The display of the faceplate.

  `PiFiWeb.Layouts` renders this LiveView inside the top of each page, and it
  renders it with `sticky: true`. The player therefore runs one process for a
  browser tab, and a move to another page keeps it. That is why the controls stay
  on the screen all the time.

  It follows the events of `PiFi.Event.Player`, so the display changes without a
  reload and without asking the player anything. The hook of `PiFiWeb.Shell`
  subscribes to the `:player` topic for each LiveView of this firmware, and this one
  is no exception: two subscriptions of one process give two copies of each event.

  A device in standby offers one control, and the control is the power button. The
  artwork, the play control and the stop control are therefore dead here while the
  device sleeps, and the large view closes.

  A radio stream has no length, so the display shows the time from the start and
  no bar. See `PiFi.Source` for the reason: `duration_ms` is `nil` for a live
  stream.

  A track with a length draws a timeline in the large view, and a person moves
  the thumb of it to move inside the track. **The player takes a skip and not a
  place**, so the page sends the difference between the two. A track that a person
  cannot move inside draws the timeline dead, because the bar still says how far
  through the track they are.

  A touch on the artwork opens the large view, which fills the screen. The state
  of that view belongs to this process, because a browser tab is its own session.

  The faceplate draws the standby control, the play control and the stop control.
  The large view draws the whole transport row as well: previous, back 15 seconds,
  play or pause, forward 30 seconds, and next. Seven round controls do not fit the
  screen of a telephone.

  A control that the source does not hold is dead. `PiFi.Source.capabilities/0`
  gives that list, and a radio station therefore shows the two skip controls disabled.
  Previous and next belong to the queue and not to a source, so a track that plays
  always has them, and the player answers `:no_more` at the end of the list. This
  page needs no knowledge of any particular service.
  """

  use PiFiWeb, :live_view

  alias PiFi.Artwork
  alias PiFi.Artwork.Accent
  alias PiFi.Event
  alias PiFi.Event.Device, as: DeviceEvents
  alias PiFi.Event.Player, as: Events
  alias PiFi.Peripheral.Battery
  alias PiFi.Playback

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    state = Playback.state!()

    socket =
      socket
      |> assign(:status, status(state))
      |> assign(:track, state.item)
      |> assign(:position_ms, state.position_ms)
      |> assign(:duration_ms, nil)
      |> assign(:stream_title, state.stream_title)
      |> assign(:artwork_path, state.artwork_path)
      |> assign(:live?, state.live?)
      |> assign(:capabilities, capabilities(state.source))
      |> assign(:expanded?, false)
      |> assign(:scrubbing?, false)
      |> assign(:reason, nil)
      |> assign(:battery, Battery.last_reading())
      |> assign(:volume, Playback.volume!())
      |> accent(state.artwork_path)

    # `PiFiWeb.Shell` subscribes each LiveView to the `:player` topic, and the battery
    # is on the `:device` topic. **The reading at mount is what earns its place beside
    # this**: the gauge reports a change once a minute at most, so a page that waited for
    # an event would draw no battery for a minute, or for an hour if the cell is steady.
    if connected?(socket), do: Event.subscribe(:device)

    # The faceplate carries this LiveView, and `PiFiWeb.Layouts` renders the
    # faceplate. The layout of the page therefore must not wrap it again.
    {:ok, socket, layout: false}
  end

  # A device on the mains publishes none of these, so a page on that device draws no
  # battery at all. See `PiFi.Peripheral.Battery`.
  @impl Phoenix.LiveView
  def handle_info(%DeviceEvents.BatteryChanged{} = event, socket) do
    {:noreply, assign(socket, :battery, event)}
  end

  @impl Phoenix.LiveView
  def handle_info(%Events.Buffering{}, socket) do
    {:noreply, assign(socket, status: :buffering, reason: nil)}
  end

  @impl Phoenix.LiveView
  def handle_info(%Events.Started{} = event, socket) do
    {:noreply,
     socket
     |> accent(event.artwork_path)
     |> assign(
       status: :playing,
       track: event.track,
       artwork_path: event.artwork_path,
       live?: event.live?,
       capabilities: capabilities(event.source),
       stream_title: nil,
       position_ms: event.position_ms,
       reason: nil
     )}
  end

  # A pause keeps the track, so this page keeps the title and the artwork and it draws
  # a play control. See `PiFi.Event.Player.Paused`.
  @impl Phoenix.LiveView
  def handle_info(%Events.Paused{position_ms: position}, socket) do
    {:noreply, assign(socket, status: :paused, position_ms: position)}
  end

  # **A person who holds the thumb of the timeline keeps it.** The player publishes
  # this once a second, and a page that moved the thumb for it would take the control
  # out of their hand. The length still arrives, because it does not move the thumb.
  @impl Phoenix.LiveView
  def handle_info(
        %Events.Progress{duration_ms: duration},
        %{assigns: %{scrubbing?: true}} = socket
      ) do
    {:noreply, assign(socket, duration_ms: duration)}
  end

  @impl Phoenix.LiveView
  def handle_info(%Events.Progress{position_ms: position, duration_ms: duration}, socket) do
    {:noreply, assign(socket, position_ms: position, duration_ms: duration)}
  end

  # The cache reads a logo after the track started, so the path arrives later. A
  # title of `nil` in such an event must not remove the title that is there.
  @impl Phoenix.LiveView
  def handle_info(%Events.MetadataChanged{title: nil, artwork_path: path}, socket)
      when is_binary(path) do
    {:noreply, socket |> accent(path) |> assign(artwork_path: path)}
  end

  @impl Phoenix.LiveView
  def handle_info(%Events.MetadataChanged{title: title}, socket) do
    {:noreply, assign(socket, stream_title: title)}
  end

  @impl Phoenix.LiveView
  def handle_info(%Events.Stopped{}, socket) do
    {:noreply,
     socket
     |> accent(nil)
     |> assign(
       status: :idle,
       track: nil,
       stream_title: nil,
       artwork_path: nil,
       position_ms: 0,
       live?: false,
       capabilities: []
     )}
  end

  @impl Phoenix.LiveView
  def handle_info(%Events.Failed{reason: reason}, socket) do
    {:noreply, assign(socket, status: :failed, reason: reason)}
  end

  # The hook of `PiFiWeb.Shell` owns `standby?`, because the whole page reads it and
  # not this LiveView alone. This closes the large view, which fills the screen and
  # would cover the one control that standby leaves alive.
  @impl Phoenix.LiveView
  # A person at another page, or at a button of the board, moves the level as well.
  def handle_info(%Events.VolumeChanged{} = event, socket) do
    {:noreply, assign(socket, :volume, Map.take(event, [:percent, :enabled?, :supported?]))}
  end

  def handle_info(%Events.Standby{entered?: true}, socket) do
    {:noreply, assign(socket, :expanded?, false)}
  end

  @impl Phoenix.LiveView
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("collapse", _params, socket) do
    {:noreply, assign(socket, :expanded?, false)}
  end

  @impl Phoenix.LiveView
  def handle_event("expand", _params, socket) do
    {:noreply, assign(socket, :expanded?, true)}
  end

  # **The slider is the source of truth and the event does not move it back.** A person
  # dragging one sends an event for each step, and a re-render that set the value from
  # the state would fight the hand that is moving it. `PiFi.Output.Volume` keeps the
  # number, so the assign follows the person and the event of another page corrects it.
  @impl Phoenix.LiveView
  def handle_event("set_volume", %{"percent" => percent}, socket) do
    case Integer.parse(percent) do
      {percent, ""} ->
        _result = Playback.set_volume(percent)

        {:noreply, assign(socket, :volume, %{socket.assigns.volume | percent: percent})}

      _other ->
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("standby", _params, socket) do
    _result = Playback.standby(not socket.assigns.standby?)
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("stop", _params, socket) do
    :ok = Playback.stop!()
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("play_pause", _params, socket) do
    _result = Playback.pause(sounding?(socket.assigns))
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("next", _params, socket) do
    _result = Playback.next()
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("previous", _params, socket) do
    _result = Playback.previous()
    {:noreply, socket}
  end

  # The player answers a control that the track does not hold with an error, and this
  # page draws such a control dead. Nothing here shows the answer, in the same way
  # that standby shows none.
  @impl Phoenix.LiveView
  def handle_event("skip", %{"ms" => ms}, socket) do
    _result = Playback.skip(String.to_integer(ms))
    {:noreply, socket}
  end

  # **The player takes a skip and not a place**, so this sends the difference between
  # where the track is and where the person put the thumb. `PiFi.Player.Skip`
  # measures what it really moved and the player reports that, so the next event of
  # the progress corrects the number that the page shows.
  @impl Phoenix.LiveView
  def handle_event("scrub", %{"position_ms" => value}, socket) do
    case Integer.parse(value) do
      {position, ""} ->
        _result = Playback.skip(position - socket.assigns.position_ms)

        {:noreply, assign(socket, position_ms: position, scrubbing?: false)}

      _other ->
        {:noreply, assign(socket, :scrubbing?, false)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("scrub_start", _params, socket),
    do: {:noreply, assign(socket, :scrubbing?, true)}

  @impl Phoenix.LiveView
  def handle_event("scrub_end", _params, socket),
    do: {:noreply, assign(socket, :scrubbing?, false)}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div id="now-playing" class="mx-auto max-w-3xl px-3 py-3 sm:px-5">
      <div class="flex items-center gap-3 sm:gap-4">
        <.round_control
          id="standby"
          click="standby"
          icon="ph-power"
          label={if @standby?, do: "Leave standby", else: "Standby"}
          pressed={@standby?}
          on?={not @standby?}
        />

        <div class={[
          "recess sheen flex grow items-center gap-3 overflow-hidden rounded-xl p-2 pr-3 transition-opacity",
          @standby? && "opacity-45"
        ]}>
          <button
            id="artwork-button"
            type="button"
            phx-click="expand"
            disabled={@standby?}
            aria-label="Show the full player"
            class="relative size-12 shrink-0 overflow-hidden rounded-lg bg-shell shadow-[inset_0_0_0_1px_var(--color-edge)]"
          >
            <img
              :if={@artwork_path}
              id="artwork"
              src={thumbnail_url(@artwork_path)}
              alt=""
              class="size-full object-cover"
            />
            <.icon
              :if={is_nil(@artwork_path)}
              name="ph-music-note"
              class="size-5 text-ink-faint"
            />
          </button>

          <div class="min-w-0 grow">
            <p class="flex items-center gap-2 text-[0.65rem] uppercase tracking-[0.18em] text-ink-faint">
              <span class={[
                "size-1.5 shrink-0 rounded-full",
                @status in [:playing, :buffering] && "led",
                @status == :buffering && "motion-safe:animate-pulse",
                @status not in [:playing, :buffering] && "bg-ink-faint/40"
              ]} />
              <span id="status">{status_text(assigns)}</span>
            </p>

            <div class="flex items-center gap-2">
              <p id="title" class="display truncate text-[0.95rem] text-ink">
                {@stream_title || title(@track) || "Nothing selected"}
              </p>
              <.live_badge :if={@live?} id="live" />
            </div>

            <p
              :if={second_line(assigns)}
              id="station"
              class={["truncate text-xs", if(@status == :failed, do: "text-red-300", else: "text-ink-dim")]}
            >
              {second_line(assigns)}
            </p>
          </div>

          <p id="position" class="numerals shrink-0 border-l border-edge pl-3 text-sm text-accent">
            {elapsed(assigns)}
          </p>

          <.battery :if={@battery} battery={@battery} />
        </div>

        <.play_control id="play-pause" status={@status} track={@track} standby?={@standby?} />

        <.round_control
          id="stop"
          click="stop"
          icon="ph-stop"
          label="Stop"
          disabled={@status == :idle or @standby?}
        />
      </div>

      <div
        :if={@expanded?}
        id="expanded"
        class="fixed inset-0 z-50 flex flex-col items-center justify-center gap-6 bg-shell/85 p-6 backdrop-blur-xl"
        phx-window-keydown="collapse"
        phx-key="escape"
      >
        <div
          class="pointer-events-none absolute inset-x-0 top-0 h-2/3 opacity-25"
          style="background: var(--color-cyan)"
        />

        <.round_control
          id="collapse"
          click="collapse"
          icon="ph-x"
          label="Close the full player"
          class="absolute right-5 top-5 size-10"
        />

        <div class="glass sheen relative flex aspect-square w-full max-w-xs items-center justify-center overflow-hidden rounded-2xl">
          <img
            :if={@artwork_path}
            id="expanded-artwork"
            src={@artwork_path}
            alt=""
            class="size-full object-cover"
          />
          <.icon
            :if={is_nil(@artwork_path)}
            name="ph-music-note"
            class="size-16 text-ink-faint"
          />
        </div>

        <div class="relative max-w-md text-center">
          <p class="flex items-center justify-center gap-2 text-xs uppercase tracking-[0.2em] text-accent">
            {status_text(assigns)}
            <.live_badge :if={@live?} id="expanded-live" />
          </p>

          <p id="expanded-title" class="mt-2 text-2xl font-medium text-ink">
            {@stream_title || title(@track) || "Nothing selected"}
          </p>

          <p :if={@stream_title && title(@track)} class="mt-1 text-ink-dim">{title(@track)}</p>
          <p :if={subtitle(@track)} class="mt-1 text-sm text-ink-faint">{subtitle(@track)}</p>
          <p class="numerals mt-4 text-lg text-ink-dim">{elapsed(assigns)}</p>

          <.timeline
            :if={is_integer(@duration_ms)}
            position_ms={@position_ms}
            duration_ms={@duration_ms}
            disabled={:skip not in @capabilities or @status not in [:playing, :paused]}
          />

          <p :if={@status == :failed} id="reason" class="mt-3 text-sm text-red-300">
            {Events.Failed.message(@reason)}
          </p>

          <div id="transport" class="mt-6 flex items-center justify-center gap-3">
            <.round_control
              id="previous"
              click="previous"
              icon="ph-rewind"
              label="Previous track"
              disabled={is_nil(@track)}
            />
            <.round_control
              id="back"
              click="skip"
              phx-value-ms="-15000"
              icon="ph-arrow-u-up-left"
              label="Back 15 seconds"
              disabled={:skip not in @capabilities or @status != :playing}
            />
            <.play_control id="expanded-play-pause" status={@status} track={@track} class="size-14" />
            <.round_control
              id="forward"
              click="skip"
              phx-value-ms="30000"
              icon="ph-arrow-u-up-right"
              label="Forward 30 seconds"
              disabled={:skip not in @capabilities or @status != :playing}
            />
            <.round_control
              id="next"
              click="next"
              icon="ph-fast-forward"
              label="Next track"
              disabled={is_nil(@track)}
            />
          </div>

          <div
            :if={@volume.enabled? and @volume.supported?}
            id="volume"
            class="mt-6 flex items-center gap-3"
          >
            <.icon name="ph-speaker-x" class="size-4 shrink-0 text-ink-faint" />
            <form phx-change="set_volume" class="grow">
              <input
                type="range"
                id="volume-level"
                name="percent"
                min="0"
                max="100"
                step="1"
                value={@volume.percent}
                aria-label="Volume"
                class="w-full accent-[var(--color-accent)]"
              />
            </form>
            <.icon name="ph-speaker-high" class="size-4 shrink-0 text-ink-faint" />
            <span class="numerals w-10 shrink-0 text-right text-sm text-ink-dim">
              {@volume.percent}
            </span>
          </div>

          <div class="mt-4 flex items-center justify-center gap-3">
            <.round_control
              id="expanded-standby"
              click="standby"
              icon="ph-power"
              label={if @standby?, do: "Leave standby", else: "Standby"}
              pressed={@standby?}
              on?={not @standby?}
            />
            <.round_control
              id="expanded-stop"
              click="stop"
              icon="ph-stop"
              label="Stop"
              disabled={@status == :idle}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  # A stream with no end has no length and no position of its own, so the display
  # says what it is. See `PiFi.Event.Player.Started`.
  #
  # The faceplate and the large view both draw this, and each element of a page needs
  # its own name, so the caller gives one.
  attr(:id, :string, required: true)

  defp live_badge(assigns) do
    ~H"""
    <span
      id={@id}
      class="shrink-0 rounded border border-[color-mix(in_oklab,var(--color-accent)_45%,transparent)] px-1.5 py-0.5 text-[0.6rem] font-medium uppercase tracking-[0.14em] text-accent"
    >
      Live
    </span>
    """
  end

  # One control for play and for pause. A person presses one place, and the icon says
  # what the press does now.
  attr(:id, :string, required: true)
  attr(:status, :atom, required: true)
  attr(:track, :map, default: nil)
  attr(:standby?, :boolean, default: false)
  attr(:class, :any, default: "size-11")

  defp play_control(assigns) do
    ~H"""
    <.round_control
      id={@id}
      click="play_pause"
      icon={if sounding?(assigns), do: "ph-pause", else: "ph-play"}
      label={if sounding?(assigns), do: "Pause", else: "Play"}
      disabled={is_nil(@track) or @standby?}
      class={@class}
    />
    """
  end

  attr(:position_ms, :integer, required: true)
  attr(:duration_ms, :integer, required: true)
  attr(:disabled, :boolean, required: true)

  # **A person moves the thumb, and the page sends one place.** `phx-debounce` waits
  # for them to settle, because each place that arrives makes the player read the file
  # to find the frame there, and a drag across the bar would send one of those for
  # every pixel.
  #
  # `phx-focus` and `phx-blur` say when a person holds the thumb, so the event of the
  # progress leaves the thumb alone while they do. A range control takes focus when a
  # mouse or a finger presses it.
  #
  # A track that a person cannot move inside still draws the bar, because the bar says
  # how far through the track they are and a radio station shows none of this at all.
  defp timeline(assigns) do
    ~H"""
    <form id="timeline" phx-change="scrub" class="mt-4">
      <input
        type="range"
        id="timeline-position"
        name="position_ms"
        min="0"
        max={@duration_ms}
        step="1000"
        value={min(@position_ms, @duration_ms)}
        disabled={@disabled}
        phx-focus="scrub_start"
        phx-blur="scrub_end"
        phx-debounce="400"
        aria-label="Position in the track"
        class="w-full accent-[var(--color-accent)] disabled:opacity-40"
      />
    </form>
    """
  end

  attr(:battery, :map, required: true)

  # **Heroicons has `battery-0`, `battery-50` and `battery-100` and nothing between
  # them**, so a cell at 30 percent would read as half full. Three elements draw the
  # exact charge, and the width of the bar is the one thing that a style attribute can
  # say and a class cannot.
  #
  # The colour says the warning and the bar says the charge, and the two are separate: a
  # cell at 15 percent means one thing under a threshold of 10 and another under 20. See
  # `PiFi.Screen.Battery`, which draws the same shape for the two screens.
  defp battery(assigns) do
    ~H"""
    <div
      id="battery"
      class="flex shrink-0 items-center gap-px"
      title={"#{@battery.percent}%"}
      aria-label={"Battery #{@battery.percent} percent"}
    >
      <div class={[
        "relative h-3 w-6 rounded-[3px] border",
        if(@battery.low?, do: "border-rose-400", else: "border-ink-dim")
      ]}>
        <div
          class={[
            "absolute inset-y-[2px] left-[2px] rounded-[1px]",
            if(@battery.low?, do: "bg-coral", else: "bg-ink-dim")
          ]}
          style={"width: #{bar_width(@battery.percent)}"}
        >
        </div>
      </div>

      <div class={[
        "h-1.5 w-[2px] rounded-[1px]",
        if(@battery.low?, do: "bg-coral", else: "bg-ink-dim")
      ]}>
      </div>
    </div>
    """
  end

  # The body is 24 pixels wide, and it draws a border of 1 and a gap of 2 on each side, so
  # 18 of them are the bar. A cell with any charge left never draws nothing.
  defp bar_width(percent) do
    "#{percent |> Kernel./(100) |> Kernel.*(18) |> round() |> max(1) |> min(18)}px"
  end

  attr(:id, :string, required: true)
  attr(:click, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:label, :string, required: true)
  attr(:on?, :boolean, default: false)
  attr(:pressed, :boolean, default: nil)
  attr(:disabled, :boolean, default: false)
  attr(:class, :any, default: "size-11")
  attr(:rest, :global)

  defp round_control(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={@click}
      disabled={@disabled}
      {@rest}
      aria-label={@label}
      aria-pressed={not is_nil(@pressed) and to_string(@pressed)}
      class={[
        "control flex shrink-0 items-center justify-center rounded-full",
        @on? && "control-on",
        @class
      ]}
    >
      <.icon name={@icon} class="size-5" />
    </button>
    """
  end

  # The display draws one line under the title. A failure needs that line, because
  # the large view is not open, and a person must read the reason.
  defp second_line(%{status: :failed, reason: reason}) when not is_nil(reason) do
    Events.Failed.message(reason)
  end

  defp second_line(%{stream_title: stream_title, track: track}) when is_binary(stream_title) do
    title(track)
  end

  defp second_line(%{track: track}), do: subtitle(track)

  defp title(%{title: title}) when is_binary(title), do: title
  defp title(_track), do: nil

  defp subtitle(%{subtitle: subtitle}) when is_binary(subtitle), do: subtitle
  defp subtitle(_track), do: nil

  # A restored track is a paused track, so a boot shows the station and a play control.
  # See `PiFi.Player`.
  # The colour of the artwork comes from the device, which read the picture when it
  # made the thumbnail. A page that opens in the middle of a track therefore reads the
  # colour before the picture arrives, and a page that shows no artwork keeps the
  # colour that the stylesheet names. See `PiFi.Artwork.Accent`.
  defp accent(socket, "/artwork/" <> name) do
    push_event(socket, "accent", %{colour: colour(Artwork.accent(name))})
  end

  defp accent(socket, _path), do: push_event(socket, "accent", %{colour: nil})

  defp colour(nil), do: nil
  defp colour(accent), do: Accent.to_css(accent)

  defp status(%{playing?: true}), do: :playing
  defp status(%{paused?: true}), do: :paused
  defp status(_state), do: :idle

  # A source names the controls that it offers, and this page draws a dead control for
  # the rest. A started event of a test names no source, so an absent one offers none.
  defp capabilities(nil), do: []
  defp capabilities(source), do: source.capabilities()

  # Buffering makes no sound yet, and a press of the control must still stop the
  # attempt.
  defp sounding?(%{status: status}), do: status in [:playing, :buffering]

  defp status_text(%{standby?: true}), do: "Standby"
  defp status_text(%{status: :paused}), do: "Paused"
  defp status_text(%{status: :playing}), do: "Playing"
  defp status_text(%{status: :buffering}), do: "Buffering"
  defp status_text(%{status: :failed}), do: "Stopped"
  defp status_text(_assigns), do: "Idle"

  # A live stream has no length, so this shows the time from the start.
  defp elapsed(%{status: :idle}), do: "--:--"

  defp elapsed(%{position_ms: position, duration_ms: nil}), do: clock(position)

  defp elapsed(%{position_ms: position, duration_ms: duration}) do
    "#{clock(position)} / #{clock(duration)}"
  end

  defp clock(milliseconds) do
    seconds = div(milliseconds, 1000)
    minutes = div(seconds, 60)

    "#{String.pad_leading(to_string(minutes), 2, "0")}:#{String.pad_leading(to_string(rem(seconds, 60)), 2, "0")}"
  end

  defp thumbnail_url(path) when is_binary(path), do: "#{path}/thumbnail"
end
