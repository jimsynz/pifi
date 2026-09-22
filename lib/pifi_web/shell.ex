defmodule PiFiWeb.Shell do
  @moduledoc """
  The assigns that the faceplate needs.

  The top row of `PiFiWeb.Layouts` shows one control for each source, and every
  page shows that row. This hook therefore reads the sources once for each page,
  and each LiveView then names the one that it shows.

  A source gives its own title and its own icon, so a new source reaches the row
  without a change here. The row draws the sources that a person left in use, so a
  source that they took out of use leaves it. See `PiFi.Source`.

  `PiFiWeb.SettingsLive` calls `assign_sources/1` again, because a person changes
  which sources are in use on that page and the row must follow at once.

  ## Standby

  A device in standby offers one control, and the control is the power button. The
  source row is dead, the settings control is dead, and the area under the faceplate
  plays nothing. `PiFiWeb.Layouts` draws that, and it needs `standby?` to do it.

  **This hook owns the subscription to the `:player` topic for every LiveView**,
  including `PiFiWeb.PlayerLive`. Two subscriptions of one process give two copies
  of each event, so no LiveView subscribes to that topic itself.

  A page therefore wakes once a second for a `PiFi.Event.Player.Progress` while a
  track plays. That is the cost of one message and one match, and the faceplate
  already sends a new position to the browser in the same second. A peripheral of the
  device is a different matter, and `c:PiFi.Peripheral.subscriptions/0` keeps a knob
  asleep for this reason.

  ## The automatic standby

  **This hook also tells the firmware that a person is at a browser.** It publishes
  `PiFi.Event.Input.PageUsed` for each event of each page, and `PiFi.AutoStandby`
  starts its period again on it.

  A control that reaches the player needs no help here, because the player publishes
  what it did. A person who browses a source, opens a settings page, or types in the
  search field reaches the player never, and a paused device therefore entered standby
  while a person was reading its screen.

  The `:handle_params` hook is what covers a page that a person loads and a link that
  patches the address. It runs for the disconnected render as well, so the publish
  reads `connected?/1` and a page load therefore sends one event and not two.
  `PiFiWeb.PlayerLive` needs no such hook, because `PiFiWeb.Layouts` renders it
  inside the page and LiveView allows `handle_params/3` at the root alone. Its
  controls send `:handle_event` in the same way as every other page.
  """

  import Phoenix.Component
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, push_event: 3]

  alias PiFi.Artwork
  alias PiFi.Device.Identity
  alias PiFi.Event
  alias PiFi.Event.Input
  alias PiFi.Event.Player, as: Events
  alias PiFi.Playback
  alias PiFi.Source
  alias PiFiWeb.Title

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

  @doc """
  Say what this page is, for the tab of a browser.

  **A page calls this rather than assigning `:page_title` itself**, because the title
  is not the page alone: it is the name of the device, and the track if one is playing.
  See `PiFiWeb.Title`. This keeps the words of the page and composes the rest, so a
  page needs no knowledge of the player.
  """
  @spec put_page(Phoenix.LiveView.Socket.t(), String.t() | nil) :: Phoenix.LiveView.Socket.t()
  def put_page(socket, page) do
    socket
    |> assign(:page_name, page)
    |> compose_title()
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
      |> assign(:page_name, nil)
      |> assign(:player_state, Playback.state!())
      |> assign(:standby?, Playback.state!().standby?)
      |> attach_title(params)
      |> attach_hook(:standby, :handle_info, &standby/2)
      |> attach_hook(:artwork_ready, :handle_info, &artwork_ready/2)
      |> attach_hook(:page_used, :handle_event, &page_used/3)
      |> attach_page_moved(params)

    {:cont, socket}
  end

  # **Every event of the player can change the tab, so this reads the player rather than
  # the event.** A `Progress` moves the position, a `Stopped` takes the track away and a
  # `Standby` replaces the lot, and matching each one here would be a second copy of
  # what the player already knows.
  #
  # It writes nothing when the words have not changed. `Progress` arrives once a second
  # and the position in the title is a whole second, so an event that lands early
  # composes the same string and sends no diff.
  defp player_moved(%_{} = event, socket) when is_struct(event) do
    if player_event?(event) do
      {:cont, socket |> assign(:player_state, Playback.state!()) |> compose_title()}
    else
      {:cont, socket}
    end
  end

  defp player_moved(_message, socket), do: {:cont, socket}

  defp player_event?(%module{}),
    do: match?(["PiFi", "Event", "Player", _name], Module.split(module))

  defp compose_title(socket) do
    title =
      Title.compose(
        Identity.name(),
        socket.assigns[:page_name],
        socket.assigns[:player_state] || %{}
      )

    if socket.assigns[:page_title] == title,
      do: socket,
      else: assign(socket, :page_title, title)
  end

  # The hook keeps `standby?` and passes the event on, because a LiveView that reads
  # the same event for its own reason must still get it. See `PiFiWeb.PlayerLive`,
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

  # **Only the page owns the title, and `PiFiWeb.PlayerLive` is not the page.** It is a
  # sticky child that `PiFiWeb.Layouts` renders inside every page, it takes the same
  # `:player` events, and it never says what page it is — so it composed the name of the
  # device and nothing else, and whichever of the two answered last won. CI caught it as
  # a title that went back to "PiFi" rather than to the page it was on.
  #
  # The params of a mount say which kind this is, in the way that `attach_page_moved/2`
  # already uses.
  defp attach_title(socket, :not_mounted_at_router), do: socket

  defp attach_title(socket, _params) do
    socket
    |> compose_title()
    |> attach_hook(:page_title, :handle_info, &player_moved/2)
  end

  # **A child LiveView cannot hold a `:handle_params` hook**, and an attach on one
  # raises. The params of a mount say which kind this is: LiveView gives
  # `:not_mounted_at_router` to `PiFiWeb.PlayerLive`, which `PiFiWeb.Layouts`
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
