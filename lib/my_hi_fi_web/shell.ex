defmodule MyHiFiWeb.Shell do
  @moduledoc """
  The assigns that the faceplate needs.

  The top row of `MyHiFiWeb.Layouts` shows one control for each source, and every
  page shows that row. This hook therefore reads the sources once for each page,
  and each LiveView then names the one that it shows.

  A source gives its own title and its own icon, so a new source reaches the row
  without a change here. The row draws the sources that a person left in use, so a
  source that they took out of use leaves it. See `MyHiFi.Source`.

  `MyHiFiWeb.SettingsLive` calls `assign_sources/1` again, because a person changes
  which sources are in use on that page and the row must follow at once.

  ## Standby

  A device in standby offers one control, and the control is the power button. The
  source row is dead, the settings control is dead, and the area under the faceplate
  plays nothing. `MyHiFiWeb.Layouts` draws that, and it needs `standby?` to do it.

  **This hook owns the subscription to the `:player` topic for every LiveView**,
  including `MyHiFiWeb.PlayerLive`. Two subscriptions of one process give two copies
  of each event, so no LiveView subscribes to that topic itself.

  A page therefore wakes once a second for a `MyHiFi.Event.Player.Progress` while a
  track plays. That is the cost of one message and one match, and the faceplate
  already sends a new position to the browser in the same second. A peripheral of the
  device is a different matter, and `c:MyHiFi.Peripheral.subscriptions/0` keeps a knob
  asleep for this reason.

  ## The automatic standby

  **This hook also tells the firmware that a person is at a browser.** It publishes
  `MyHiFi.Event.Input.PageUsed` for each event of each page, and `MyHiFi.AutoStandby`
  starts its period again on it.

  A control that reaches the player needs no help here, because the player publishes
  what it did. A person who browses a source, opens a settings page, or types in the
  search field reaches the player never, and a paused device therefore entered standby
  while a person was reading its screen.

  The `:handle_params` hook is what covers a page that a person loads and a link that
  patches the address. It runs for the disconnected render as well, so the publish
  reads `connected?/1` and a page load therefore sends one event and not two.
  `MyHiFiWeb.PlayerLive` needs no such hook, because `MyHiFiWeb.Layouts` renders it
  inside the page and LiveView allows `handle_params/3` at the root alone. Its
  controls send `:handle_event` in the same way as every other page.
  """

  import Phoenix.Component
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, push_event: 3]

  alias MyHiFi.Artwork
  alias MyHiFi.Event
  alias MyHiFi.Event.Input
  alias MyHiFi.Event.Player, as: Events
  alias MyHiFi.Playback
  alias MyHiFi.Source

  @doc """
  Read the sources in use, for the top row of the faceplate.
  """
  @spec assign_sources(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_sources(socket) do
    sources =
      Enum.map(Source.enabled(), fn module ->
        %{module: module, title: module.title(), icon: module.icon(), slug: Source.slug(module)}
      end)

    assign(socket, :sources, sources)
  end

  def on_mount(:default, params, _session, socket) do
    if connected?(socket) do
      Event.subscribe(:player)
      Artwork.subscribe()
    end

    socket =
      socket
      |> assign_sources()
      |> assign(:current_source, nil)
      |> assign(:standby?, Playback.state!().standby?)
      |> attach_hook(:standby, :handle_info, &standby/2)
      |> attach_hook(:artwork_ready, :handle_info, &artwork_ready/2)
      |> attach_hook(:page_used, :handle_event, &page_used/3)
      |> attach_page_moved(params)

    {:cont, socket}
  end

  # The hook keeps `standby?` and passes the event on, because a LiveView that reads
  # the same event for its own reason must still get it. See `MyHiFiWeb.PlayerLive`,
  # which closes its large view on the same event.
  defp standby(%Events.Standby{entered?: entered?}, socket) do
    {:cont, assign(socket, :standby?, entered?)}
  end

  defp standby(_message, socket), do: {:cont, socket}

  # **The browser keeps the answer that it got for an address.** A list draws the
  # address of each picture without a read, and the job that fetches one finishes a
  # moment later, so the image holds a 404 that no redraw of the page can change. This
  # names the address that arrived, and `assets/js/cover.js` asks for it again.
  #
  # The event carries one address and not a redraw of the page, because a list of 25
  # rows would otherwise ask the device for 25 pictures each time that one of them
  # arrived.
  defp artwork_ready(%Ash.Notifier.Notification{} = notification, socket) do
    case Artwork.ready(notification) do
      {:ok, path} -> {:halt, push_event(socket, "artwork-ready", %{path: path})}
      :error -> {:halt, socket}
    end
  end

  defp artwork_ready(_message, socket), do: {:cont, socket}

  # **A child LiveView cannot hold a `:handle_params` hook**, and an attach on one
  # raises. The params of a mount say which kind this is: LiveView gives
  # `:not_mounted_at_router` to `MyHiFiWeb.PlayerLive`, which `MyHiFiWeb.Layouts`
  # renders inside each page.
  defp attach_page_moved(socket, :not_mounted_at_router), do: socket

  defp attach_page_moved(socket, _params),
    do: attach_hook(socket, :page_moved, :handle_params, &page_moved/3)

  defp page_used(_event, _params, socket) do
    publish_page_used(socket)

    {:cont, socket}
  end

  defp page_moved(_params, _uri, socket) do
    if connected?(socket), do: publish_page_used(socket)

    {:cont, socket}
  end

  defp publish_page_used(socket) do
    Event.publish(:input, %Input.PageUsed{page: socket.view})
  end
end
