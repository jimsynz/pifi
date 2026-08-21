defmodule MyHiFiWeb.NowPlayingLive do
  @moduledoc """
  What the device is playing.

  It subscribes to the `:player` topic and follows the events of
  `MyHiFi.Event.Player`, so the page changes without a reload and without asking
  the player anything.

  A radio stream has no length, so the page shows the time from the start and no
  bar. See `MyHiFi.Source` for the reason: `duration_ms` is `nil` for a live
  stream.
  """

  use MyHiFiWeb, :live_view

  alias MyHiFi.Event
  alias MyHiFi.Event.Player, as: Events

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Event.subscribe(:player)

    state = MyHiFi.Player.state()

    {:ok,
     socket
     |> assign(:page_title, "Now playing")
     |> assign(:status, if(state.playing?, do: :playing, else: :idle))
     |> assign(:track, state.track)
     |> assign(:standby?, state.standby?)
     |> assign(:position_ms, state.position_ms)
     |> assign(:duration_ms, nil)
     |> assign(:stream_title, state.stream_title)
     |> assign(:reason, nil)}
  end

  @impl Phoenix.LiveView
  def handle_info(%Events.Buffering{}, socket) do
    {:noreply, assign(socket, status: :buffering, reason: nil)}
  end

  @impl Phoenix.LiveView
  def handle_info(%Events.Started{track: track}, socket) do
    {:noreply,
     assign(socket,
       status: :playing,
       track: track,
       stream_title: nil,
       position_ms: 0,
       reason: nil
     )}
  end

  @impl Phoenix.LiveView
  def handle_info(%Events.Progress{position_ms: position, duration_ms: duration}, socket) do
    {:noreply, assign(socket, position_ms: position, duration_ms: duration)}
  end

  @impl Phoenix.LiveView
  def handle_info(%Events.MetadataChanged{title: title}, socket) do
    {:noreply, assign(socket, stream_title: title)}
  end

  @impl Phoenix.LiveView
  def handle_info(%Events.Stopped{}, socket) do
    {:noreply, assign(socket, status: :idle, track: nil, stream_title: nil, position_ms: 0)}
  end

  @impl Phoenix.LiveView
  def handle_info(%Events.Failed{reason: reason}, socket) do
    {:noreply, assign(socket, status: :failed, reason: reason)}
  end

  @impl Phoenix.LiveView
  def handle_info(%Events.Standby{entered?: entered?}, socket) do
    {:noreply, assign(socket, standby?: entered?)}
  end

  @impl Phoenix.LiveView
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("stop", _params, socket) do
    :ok = MyHiFi.Player.stop()
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("standby", _params, socket) do
    _result = MyHiFi.Player.standby(not socket.assigns.standby?)
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div id="now-playing" class="mx-auto max-w-xl p-6">
      <div class="flex items-baseline justify-between mb-6">
        <h1 class="text-2xl font-semibold">Now playing</h1>
        <nav class="flex gap-4 text-sm">
          <.link navigate={~p"/browse"} class="underline">Browse</.link>
          <.link navigate={~p"/settings"} class="underline">Settings</.link>
        </nav>
      </div>

      <div class="flex gap-6 items-start">
        <div class="w-32 h-32 shrink-0 rounded bg-zinc-200 overflow-hidden flex items-center justify-center">
          <%= if artwork(@track) do %>
            <img id="artwork" src={artwork(@track)} alt="" class="w-full h-full object-cover" />
          <% else %>
            <span class="text-zinc-500 text-sm">No artwork</span>
          <% end %>
        </div>

        <div class="grow">
          <p id="status" class="text-sm uppercase tracking-wide text-zinc-500">
            {status_text(assigns)}
          </p>

          <p id="title" class="text-xl font-medium mt-1">
            {@stream_title || title(@track) || "Nothing selected"}
          </p>

          <%= if @stream_title && title(@track) do %>
            <p id="station" class="text-zinc-600">{title(@track)}</p>
          <% end %>

          <%= if subtitle(@track) do %>
            <p id="subtitle" class="text-sm text-zinc-500">{subtitle(@track)}</p>
          <% end %>

          <p id="position" class="mt-3 font-mono text-sm">{elapsed(assigns)}</p>

          <%= if @status == :failed do %>
            <p id="reason" class="mt-2 text-sm text-red-700">
              The player stopped: {inspect(@reason)}
            </p>
          <% end %>
        </div>
      </div>

      <div class="mt-8 flex gap-3">
        <button
          id="stop"
          type="button"
          phx-click="stop"
          disabled={@status == :idle}
          class="rounded px-4 py-2 bg-zinc-800 text-white disabled:opacity-40"
        >
          Stop
        </button>

        <button
          id="standby"
          type="button"
          phx-click="standby"
          class="rounded px-4 py-2 border border-zinc-400"
        >
          {if @standby?, do: "Leave standby", else: "Standby"}
        </button>
      </div>
    </div>
    """
  end

  defp artwork(%{artwork: artwork}) when is_binary(artwork) and artwork != "", do: artwork
  defp artwork(_track), do: nil

  defp title(%{title: title}) when is_binary(title), do: title
  defp title(_track), do: nil

  defp subtitle(%{subtitle: subtitle}) when is_binary(subtitle), do: subtitle
  defp subtitle(_track), do: nil

  defp status_text(%{standby?: true}), do: "Standby"
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
end
