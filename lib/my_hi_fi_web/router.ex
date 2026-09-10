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
    #
    # **`connect-src` names the two schemes of a socket, and `'self'` cannot do that
    # work.** CSP Level 3 says that `'self'` matches `ws:` and `wss:` of the same host,
    # and WebKit does not hold that rule, so Safari and every browser of iOS refused
    # the LiveView socket while they drew the page. LiveView then used long poll after
    # 2.5 seconds, so the interface worked and the socket never opened.
    #
    # A scheme and not a host: this device answers on its IP address and on more than
    # one mDNS name, so no list of hosts can name them all. That is the reason that
    # `check_origin` is `false` as well. See `config/target.exs`.
    plug(:put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; connect-src 'self' ws: wss:; " <>
          "img-src 'self' data:; style-src 'self' 'unsafe-inline'"
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
    # The rest of the address is where a person is in the tree, one segment for each
    # level. See `MyHiFiWeb.BrowseLive`.
    live("/browse/:source", BrowseLive)
    live("/browse/:source/*path", BrowseLive)
    live("/search/:source", SearchLive)
    live("/queue", QueueLive)
    live("/playlists", PlaylistLive, :index)
    live("/playlists/:id", PlaylistLive, :show)
    live("/settings", SettingsLive, :menu)
    live("/settings/device", SettingsLive, :device)
    live("/settings/output", SettingsLive, :output)
    live("/settings/output/hardware", SettingsLive, :hardware)
    live("/settings/sources", SettingsLive, :sources)
    live("/settings/sources/:source", SettingsLive, :source)
    live("/settings/peripherals", SettingsLive, :peripherals)
    live("/settings/standby", SettingsLive, :standby)
    live("/settings/network", SettingsLive, :network)
    live("/settings/storage", SettingsLive, :storage)
    get("/artwork/:name", ArtworkController, :show)
    get("/artwork/:name/thumbnail", ArtworkController, :thumbnail)
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
