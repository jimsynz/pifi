defmodule PiFiWeb.ManifestController do
  @moduledoc """
  The web app manifest, which is what a telephone reads before it adds this to a home
  screen.

  **It is a route and not a file in `priv/static`, because the name is not the same on
  two devices.** A person names their PiFi, and a household with one in the kitchen and
  one in the study would otherwise install two icons that both said the same word. The
  icons are static and the name is not, so this reads `PiFi.Device.Identity` the way
  every other surface does.

  `PiFi.Device.Identity.default_name/0` is the name of the product, which is what an
  unnamed device answers to, so a device that nobody has named still installs as
  something a person recognises.
  """

  use PiFiWeb, :controller

  alias PiFi.Device.Identity

  @doc """
  The manifest for this device.

  **`display` is `standalone` rather than `fullscreen`.** A person controlling a stereo
  reaches for the clock and the battery of their telephone as often as for the
  transport, and a player that hid the status bar would be taking the room over.
  """
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    manifest = %{
      name: Identity.name(),
      short_name: Identity.default_name(),
      description: "Your music, on your stereo.",
      start_url: "/",
      scope: "/",
      display: "standalone",
      orientation: "portrait",
      # The shell of the interface, so the frame around a page that is still loading is
      # the colour that the page will be. `--color-shell` of `assets/css/app.css`.
      background_color: "#f7f2e7",
      # The cyan of the mark, which is what the top row and every current control use.
      theme_color: "#2fc6e8",
      icons: [
        %{src: ~p"/icons/icon-192.png", sizes: "192x192", type: "image/png"},
        %{src: ~p"/icons/icon-512.png", sizes: "512x512", type: "image/png"},
        %{
          src: ~p"/icons/icon-maskable-512.png",
          sizes: "512x512",
          type: "image/png",
          purpose: "maskable"
        }
      ]
    }

    conn
    |> put_resp_content_type("application/manifest+json")
    |> send_resp(200, JSON.encode!(manifest))
  end
end
