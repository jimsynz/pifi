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
  """

  import Phoenix.Component

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
    {:cont, socket |> assign_sources() |> assign(:current_source, nil)}
  end
end
