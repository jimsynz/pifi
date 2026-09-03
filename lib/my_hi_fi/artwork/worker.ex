defmodule MyHiFi.Artwork.Worker do
  @moduledoc """
  Reads one station logo and stores it.

  The player asks for this job when it starts a track whose logo the cache does
  not hold. The job then tells the `:player` topic, so a page that is open shows
  the logo without a reload.

  A station that gives no image, or an image that is too large, gives no retry. A
  network fault gives one, and Oban holds the count.
  """

  # **A job that waits collapses with the ask that follows it.** `MyHiFi.Jellyfin.Fill`
  # asks for the picture of each container that it writes, and a library of 5,205 of
  # them is read again every day. Without this each read wrote 5,205 more rows of the
  # queue for pictures that the one before it had already asked for, and this device
  # runs for years on an SD card.
  #
  # `states` leaves a job that finished out, so a picture that an eviction took is read
  # again when something asks for it. The arguments hold one address and no nil, so the
  # trap of the SQLite engine that `CLAUDE.md` names does not reach this.
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Logger

  alias MyHiFi.Artwork
  alias MyHiFi.Event
  alias MyHiFi.Event.Player, as: Events

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url}}) do
    case Artwork.fetch(url) do
      {:ok, name} ->
        generate_thumbnail(name)
        Event.publish(:player, %Events.MetadataChanged{artwork_path: "/artwork/#{name}"})
        :ok

      # A station that holds no image cannot start to hold one, so this job stops.
      {:error, {:not_an_image, type}} ->
        Logger.info("#{url} gave #{inspect(type)} and not an image.")
        {:cancel, :not_an_image}

      {:error, {:too_large, bytes}} ->
        Logger.info("#{url} gave #{bytes} bytes, and that is too large for a logo.")
        {:cancel, :too_large}

      {:error, {:status, status}} when status in 400..499 ->
        {:cancel, {:status, status}}

      # An address that holds no scheme can never hold a picture. Radio Browser sends
      # the text `"null"` for 4 of the 247 New Zealand stations.
      {:error, :no_address} ->
        {:cancel, :no_address}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_thumbnail(name) do
    with {:ok, entry} <- MyHiFi.Cache.fetch("artwork", name) do
      case Artwork.generate_thumbnail(entry) do
        {:ok, _variant} -> :ok
        {:error, :unsupported_format} -> :ok
        {:error, :vipsthumbnail_not_found} -> :ok
        {:error, reason} -> Logger.warning("Thumbnail generation failed: #{inspect(reason)}")
      end
    end
  end

  @doc "Ask for one logo, unless the cache holds it."
  @spec enqueue(String.t() | nil) :: :ok
  def enqueue(url) when is_binary(url) and url != "" do
    if Artwork.readable?(url) and is_nil(Artwork.name(url)) do
      %{"url" => url} |> new() |> Oban.insert()
    end

    :ok
  end

  def enqueue(_url), do: :ok
end
