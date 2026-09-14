defmodule MyHiFi.Artwork.Worker do
  @moduledoc """
  Reads one picture and stores it.

  A station that gives no image, or an image that is too large, gives no retry. A
  network fault gives one, and Oban keeps the count.

  ## Who hears that a picture arrived

  **A job tells the `:player` topic only when the caller asks it to.** The player asks
  for the logo of the track that it is starting, and a page that is open then shows
  that logo with no reload. `MyHiFiWeb.PlayerLive` draws whatever such an event names,
  and it takes the accent colour of the interface from it.

  `MyHiFi.Jellyfin.Fill` asks for the picture of each container that it writes, and a
  library has 5,205 of them. Those jobs must tell that topic nothing: each one that
  finished announced its own picture as though it were the track that plays, so a
  person reading the library watched the panel move through album covers while it said
  `Nothing selected`, and the colour of the whole interface moved with them.

  **The announcement is off unless a caller asks for it**, so a caller that forgets
  leaves the panel alone. That is the safe way for this to fail.

  A job of one address collapses with another of the same address, whatever either one
  asks for, because `keys` names the address alone. Two jobs of one picture would read
  it twice. The cost is that a job of the sync may take the place of one that the
  player asked for, and the panel then waits for the next event of the player to show
  that logo.
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
  # **A queue of its own, and one job of it at a time.** A read of a library asks for a
  # picture of every container that it writes, so this worker arrives in thousands and
  # every other job of this firmware arrives in ones. Each job reads a picture over the
  # network and then runs `vipsthumbnail` over the bytes, and this board holds four
  # cores that a stream of audio also needs.
  #
  # **`default` cannot serve both.** Lowering that queue to one would put this behind a
  # read of a library that runs for 80 minutes, and `cache_audio` of
  # `MyHiFi.Playback.Item` is in it: a person who marked an album would then wait for
  # the read before a note of it reached the card. A queue of its own holds the pictures
  # to one at a time and leaves everything else as it was.
  use Oban.Worker,
    queue: :artwork,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:url],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Logger

  alias MyHiFi.Artwork
  alias MyHiFi.Event
  alias MyHiFi.Event.Player, as: Events

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url} = args}) do
    case Artwork.fetch(url) do
      {:ok, name} ->
        generate_thumbnail(name)
        announce(name, args["announce"])
        :ok

      # A station with no image cannot start to hold one, so this job stops.
      {:error, {:not_an_image, type}} ->
        Logger.info("#{url} gave #{inspect(type)} and not an image.")
        {:cancel, :not_an_image}

      {:error, {:too_large, bytes}} ->
        Logger.info("#{url} gave #{bytes} bytes, and that is too large for a logo.")
        {:cancel, :too_large}

      {:error, {:status, status}} when status in 400..499 ->
        {:cancel, {:status, status}}

      # An address with no scheme can never hold a picture. Radio Browser sends
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

  @doc """
  Ask for one picture, unless the cache has it.

  `announce?` says whether the job tells the `:player` topic that the picture arrived.
  The player asks for the logo of the track that it starts, and it passes `true`. Every
  other caller leaves it alone. See the moduledoc.
  """
  @spec enqueue(String.t() | nil, boolean()) :: :ok
  def enqueue(url, announce? \\ false)

  def enqueue(url, announce?) when is_binary(url) and url != "" do
    if Artwork.readable?(url) and is_nil(Artwork.name(url)) do
      %{"url" => url, "announce" => announce?} |> new() |> Oban.insert()
    end

    :ok
  end

  def enqueue(_url, _announce?), do: :ok

  defp announce(name, true) do
    Event.publish(:player, %Events.MetadataChanged{artwork_path: "/artwork/#{name}"})
  end

  defp announce(_name, _announce?), do: :ok
end
