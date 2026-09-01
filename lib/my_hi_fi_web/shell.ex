defmodule MyHiFiWeb.Shell do
  @moduledoc """
  The assigns that the faceplate needs.

  The top row of `MyHiFiWeb.Layouts` shows one control for each source, and every
  page shows that row. This hook therefore reads the sources once for each page,
  and each LiveView then names the one that it shows.

  A source gives its own title and its own icon, so a new source reaches the row
  without a change here. The row holds the sources that a person left in use, so a
  source that they took out of use leaves it. See `MyHiFi.Source`.

  `MyHiFiWeb.SettingsLive` calls `assign_sources/1` again, because a person changes
  which sources are in use on that page and the row must follow at once.

  ## Standby

  A device in standby offers one control, and the control is the power button. The
  source row is dead, the settings control is dead, and the area under the faceplate
  holds nothing. `MyHiFiWeb.Layouts` draws that, and it needs `standby?` to do it.

  **This hook owns the subscription to the `:player` topic for every LiveView**,
  including `MyHiFiWeb.PlayerLive`. Two subscriptions of one process give two copies
  of each event, so no LiveView subscribes to that topic itself.

  A page therefore wakes once a second for a `MyHiFi.Event.Player.Progress` while a
  track plays. That is the cost of one message and one match, and the faceplate
  already sends a new position to the browser in the same second. A peripheral of the
  device is a different matter, and `c:MyHiFi.Peripheral.subscriptions/0` keeps a knob
  asleep for this reason.
  """

  import Phoenix.Component
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias MyHiFi.Event
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

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Event.subscribe(:player)

    socket =
      socket
      |> assign_sources()
      |> assign(:current_source, nil)
      |> assign(:standby?, Playback.state!().standby?)
      |> attach_hook(:standby, :handle_info, &standby/2)

    {:cont, socket}
  end

  # The hook keeps `standby?` and passes the event on, because a LiveView that reads
  # the same event for its own reason must still get it. See `MyHiFiWeb.PlayerLive`,
  # which closes its large view on the same event.
  defp standby(%Events.Standby{entered?: entered?}, socket) do
    {:cont, assign(socket, :standby?, entered?)}
  end

  defp standby(_message, socket), do: {:cont, socket}
end
