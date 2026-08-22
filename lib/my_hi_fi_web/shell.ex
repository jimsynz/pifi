defmodule MyHiFiWeb.Shell do
  @moduledoc """
  The assigns that the faceplate needs.

  The top row of `MyHiFiWeb.Layouts` shows one control for each source, and every
  page shows that row. This hook therefore reads the sources once for each page,
  and each LiveView then names the one that it shows.

  A source gives its own title and its own icon, so a new source reaches the row
  without a change here. See `MyHiFi.Source`.
  """

  import Phoenix.Component

  alias MyHiFi.Source

  def on_mount(:default, _params, _session, socket) do
    sources =
      Enum.map(Source.all(), fn module ->
        %{module: module, title: module.title(), icon: module.icon(), slug: Source.slug(module)}
      end)

    {:cont,
     socket
     |> assign(:sources, sources)
     |> assign(:current_source, nil)}
  end
end
