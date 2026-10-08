defmodule PiFi.HomeAssistant.Artwork do
  @moduledoc """
  The cover of what is playing, as a camera that Home Assistant can draw.

  ## Why a camera, and not the media player

  **The ESPHome protocol carries no media metadata at all.** `MediaPlayerStateResponse`
  holds a state, a volume and a mute flag, and nothing else — no title, no artist and no
  picture — so `PiFi.HomeAssistant.Player` has nowhere to put the artwork and the
  ESPHome media player of Home Assistant reads none. A camera is the one entity of the
  protocol that carries bytes, so this publishes the cover as a camera image.

  A dashboard can draw that camera on its own. To put it back in the media control
  card, Home Assistant needs a universal media player that takes the picture from here
  and everything else from the player:

      media_player:
        - platform: universal
          name: PiFi
          children:
            - media_player.pifi
          attributes:
            entity_picture: camera.pifi_artwork|entity_picture

  The `attributes` option of that platform overrides `media_image_url`, which is what
  the card draws.

  ## It always holds a picture

  **A camera with no image breaks the bridge.** `Homex.Adapter.ESPHome` builds the
  first frame of every entity from its values, and the camera platform matches on an
  `:image` key, so an entity that never set one raises as Home Assistant connects. The
  idle picture is therefore set before anything plays, and a stop puts it back.

  The idle picture is the one that the device screens draw: the picture a person gave,
  and the mark of the product when they gave none. See `PiFi.Device.Identity`.

  ## The bytes go as they are

  Home Assistant labels every ESPHome camera image `image/jpeg`. The thumbnails of
  `PiFi.Artwork` are JPEG, so they match, and the mark of the product is a PNG that
  does not. That is safe: a browser sniffs the bytes of an image it is asked to draw
  and uses what it finds, so converting the PNG would buy nothing and would cost a run
  of `vipsthumbnail` on each start.
  """

  use Homex.Entity.Camera, id: :pifi_artwork, name: "Artwork"

  require Logger

  alias Homex.Entity.Camera
  alias PiFi.Artwork
  alias PiFi.Device.Identity
  alias PiFi.Event
  alias PiFi.Event.Device, as: DeviceEvents
  alias PiFi.Event.Player, as: Events
  alias PiFi.Playback

  # Sobelow reads `@sobelow_skip` from the source. This registration stops the
  # compiler warning that no Elixir code reads the attribute.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  # The larger of the two sets that `priv/splash` ships. Home Assistant draws the
  # picture at whatever size the card is, so this is about detail and not about fit.
  @splash_size {320, 240}

  @impl Homex.Entity.Camera
  def handle_init(entity) do
    Event.subscribe(:player)
    Event.subscribe(:device)

    drawn(entity, Playback.state!().artwork_path)
  end

  @impl Homex.Entity.Camera
  def handle_info(%Events.Started{artwork_path: path}, entity), do: drawn(entity, path)

  # A stream names a new track in the middle of itself, and it names a picture with it
  # often enough. One that names none leaves the cover of the station where it was.
  def handle_info(%Events.MetadataChanged{artwork_path: nil}, entity), do: entity
  def handle_info(%Events.MetadataChanged{artwork_path: path}, entity), do: drawn(entity, path)

  def handle_info(%Events.Stopped{}, entity), do: drawn(entity, nil)
  def handle_info(%Events.Failed{}, entity), do: drawn(entity, nil)

  def handle_info(%Events.Standby{entered?: true}, entity), do: drawn(entity, nil)

  def handle_info(%Events.Standby{entered?: false}, entity),
    do: drawn(entity, Playback.state!().artwork_path)

  # A person who changes the picture of their device sees it here as well, and only
  # when nothing is covering it.
  def handle_info(%DeviceEvents.IdentityChanged{}, entity) do
    case Playback.state!().artwork_path do
      nil -> drawn(entity, nil)
      _path -> entity
    end
  end

  def handle_info(_message, entity), do: entity

  defp drawn(entity, path) do
    case picture(path) do
      {:ok, bytes} ->
        Camera.set_image(entity, bytes)

      :error ->
        Logger.debug("Home Assistant gets no artwork for #{inspect(path)}.")

        entity
    end
  end

  defp picture(nil), do: idle()

  defp picture("/artwork/" <> name) do
    with {:ok, path, _content_type, _etag} <- Artwork.serve_thumbnail(name),
         {:ok, bytes} <- read(path) do
      {:ok, bytes}
    else
      _other -> idle()
    end
  end

  defp picture(_address), do: idle()

  defp idle do
    with nil <- person_splash(),
         nil <- Identity.shipped_splash(@splash_size) do
      :error
    else
      path -> read(path)
    end
  end

  defp person_splash do
    with "/artwork/" <> name <- Identity.splash_path(),
         {:ok, path, _content_type, _etag} <- Artwork.serve_thumbnail(name) do
      path
    else
      _other -> nil
    end
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} -> :error
    end
  end
end
