defmodule PiFiWeb do
  @moduledoc """
  Shared imports and macros for PiFi's Phoenix modules.

  Use `PiFiWeb` with `:controller`, `:live_view`, `:live_component`, or `:html`.
  """

  def static_paths, do: ~w(assets fonts icons images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView, layout: {PiFiWeb.Layouts, :app}

      on_mount(PiFiWeb.Shell)

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller, only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: PiFiWeb.Endpoint,
        router: PiFiWeb.Router,
        statics: PiFiWeb.static_paths()
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML

      import PiFiWeb.CoreComponents

      alias Phoenix.LiveView.JS

      alias PiFiWeb.Layouts

      unquote(verified_routes())
      use Gettext, backend: PiFiWeb.Gettext
    end
  end

  @doc "Dispatch to the requested web module setup."
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
