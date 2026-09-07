defmodule MyHiFiWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_hi_fi

  @session_options [
    store: :cookie,
    key: "_my_hi_fi_key",
    signing_salt: "dPrK3YaM",
    same_site: "Lax"
  ]

  # **This device serves the websocket transport and no other.** Long poll is the
  # fallback of a browser that cannot open a websocket, and this device is reached over
  # a home network by a browser of this decade, so no such client exists here. The
  # policy of `MyHiFiWeb.Router` names `ws:` for the same reason, and it was the one
  # thing that made a modern browser fail.
  #
  # **The fallback cost more than it gave.** Phoenix writes `phx:fallback:LongPoll` to
  # `sessionStorage` when a websocket does not pass a health check in time, and every
  # connection of that tab then skips the websocket without trying. One busy moment on
  # a device that answers a library of thousands of albums therefore held a tab on long
  # poll after the device was idle again, and only a person clearing that key by hand
  # brought the socket back. With no such transport to reach, the client retries the
  # websocket instead, which is what a device that was busy for a moment needs.
  #
  # A client that needs it again takes `longpoll: [connect_info: [session:
  # @session_options]]` here and `longPollFallbackMs` in `assets/js/app.js`.
  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Static,
    at: "/",
    from: :my_hi_fi,
    gzip: not code_reloading?,
    only: MyHiFiWeb.static_paths(),
    raise_on_missing_only: code_reloading?
  )

  if code_reloading? do
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(MyHiFiWeb.Router)
end
