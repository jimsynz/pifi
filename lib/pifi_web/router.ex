defmodule PiFiWeb.Router do
  use PiFiWeb, :router

  import Oban.Web.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {PiFiWeb.Layouts, :root})
    plug(:protect_from_forgery)

    plug(:put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; connect-src 'self' ws: wss:; img-src 'self' data:; style-src 'self' 'unsafe-inline'"
    })
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/api", PiFiWeb do
    pipe_through(:api)
  end

  scope "/", PiFiWeb do
    pipe_through(:browser)

    live("/", BrowseLive)
    live("/browse/:source", BrowseLive)
    live("/browse/:source/*path", BrowseLive)
    live("/search", SearchAllLive)
    live("/search/:source", SearchLive)
    live("/queue", QueueLive)
    live("/history", HistoryLive)
    live("/playlists", PlaylistLive, :index)
    live("/playlists/:id", PlaylistLive, :show)
    live("/settings", SettingsLive, :menu)
    live("/settings/device", SettingsLive, :device)
    live("/settings/output", SettingsLive, :output)
    live("/settings/output/hardware", SettingsLive, :hardware)
    live("/settings/sources", SettingsLive, :sources)
    live("/settings/sources/:source", SettingsLive, :source)
    live("/settings/peripherals", SettingsLive, :peripherals)
    live("/settings/peripherals/:peripheral", SettingsLive, :peripheral)
    live("/settings/crossfade", SettingsLive, :crossfade)
    live("/settings/timezone", SettingsLive, :timezone)
    live("/settings/standby", SettingsLive, :standby)
    live("/settings/screen", SettingsLive, :screen)
    live("/settings/network", SettingsLive, :network)
    live("/settings/storage", SettingsLive, :storage)
    live("/settings/firmware", SettingsLive, :firmware)
    live("/settings/home-assistant", SettingsLive, :home_assistant)
    live("/settings/bluetooth", SettingsLive, :bluetooth)
    get("/site.webmanifest", ManifestController, :show)
    get("/artwork/:name", ArtworkController, :show)
    get("/artwork/:name/thumbnail", ArtworkController, :thumbnail)
  end

  if Application.compile_env(:pifi, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: PiFiWeb.Telemetry)
    end

    scope "/" do
      pipe_through(:browser)

      oban_dashboard("/oban")
    end
  end
end
