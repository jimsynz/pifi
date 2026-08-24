defmodule MyHiFiWeb.Router do
  use MyHiFiWeb, :router

  import Oban.Web.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {MyHiFiWeb.Layouts, :root})
    plug(:protect_from_forgery)
    # The artwork cache serves each station logo from this device, so no page asks
    # another server for anything. See `MyHiFi.Artwork`.
    plug(:put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'"
    })
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/api", MyHiFiWeb do
    pipe_through(:api)
  end

  scope "/", MyHiFiWeb do
    pipe_through(:browser)

    live("/", BrowseLive)
    live("/browse/:source", BrowseLive)
    live("/settings", SettingsLive, :menu)
    live("/settings/output", SettingsLive, :output)
    live("/settings/sources", SettingsLive, :sources)
    live("/settings/sources/:source", SettingsLive, :source)
    live("/settings/network", SettingsLive, :network)
    live("/settings/storage", SettingsLive, :storage)
    get("/artwork/:name", ArtworkController, :show)
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
