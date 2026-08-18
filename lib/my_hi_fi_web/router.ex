defmodule MyHiFiWeb.Router do
  use MyHiFiWeb, :router

  import Oban.Web.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {MyHiFiWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers, %{"content-security-policy" => "default-src 'self'"})
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/api", MyHiFiWeb do
    pipe_through(:api)
  end

  if Application.compile_env(:my_hi_fi, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: MyHiFiWeb.Telemetry)
    end

    scope "/" do
      pipe_through(:browser)

      oban_dashboard("/oban")
    end
  end
end
