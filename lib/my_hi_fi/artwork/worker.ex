defmodule MyHiFi.Artwork.Worker do
  @moduledoc """
  Reads the pictures of one list and stores them.

  A station that gives no image, or an image that is too large, gives no retry for that
  address, and the rest of the list goes on. A network fault gives a retry of the whole
  job, and an address that already arrived costs nothing then, because `fetch/1` of
  `MyHiFi.Artwork` answers from the cache.

  ## One job for a list, and not one job for each picture

  **A read of a library asks for thousands of pictures at one time.**
  `MyHiFi.Jellyfin.Fill` asks for the picture of each container that it writes, and one
  library holds 5,205 of them. One job for each address wrote 5,205 rows of the queue,
  and each of those rows costs the card a write, a read and a delete. This device runs
  for years on an SD card.

  `MyHiFi.Artwork.ensure/1` therefore writes one job for a batch of addresses, in one
  statement. See `batch_size/0`.

  **The addresses of one job are read together, and the thumbnails are made one at a
  time.** A read is network, and a board that waits for one server can wait for four.
  `vipsthumbnail` is the four cores that a stream of audio also needs, so the pictures
  queue for it.

  ## Who hears that a picture arrived

  **A job tells the `:player` topic only when the caller asks it to.** The player asks
  for the logo of the track that it is starting, and a page that is open then shows
  that logo with no reload. `MyHiFiWeb.PlayerLive` draws whatever such an event names,
  and it takes the accent colour of the interface from it.

  Those thousands of jobs of a library must tell that topic nothing: each one that
  finished announced its own picture as though it were the track that plays, so a
  person reading the library watched the panel move through album covers while it said
  `Nothing selected`, and the colour of the whole interface moved with them.

  **The announcement is off unless a caller asks for it**, so a caller that forgets
  leaves the panel alone. That is the safe way for this to fail.

  **A picture that a person is waiting for goes first.** The player asks for the logo of
  the track that starts, and a read of a library holds 80 minutes of jobs in front of
  it. Such an ask therefore carries the first priority of Oban and a read of a library
  carries a later one, so the panel of the person gets its picture while the library
  reads on.

  ## A job of an older firmware

  A device that takes this firmware holds jobs of the one before it, and each of those
  names `url` and no `urls`. `perform/1` reads both, so no job of a queue that is
  already written is lost.
  """

  # **A queue of its own, and one job of it at a time.** A read of a library asks for a
  # picture of every container that it writes, so this worker arrives in thousands and
  # every other job of this firmware arrives in ones. Each job reads pictures over the
  # network and then runs `vipsthumbnail` over the bytes, and this board holds four
  # cores that a stream of audio also needs.
  #
  # **`default` cannot serve both.** Lowering that queue to one would put this behind a
  # read of a library that runs for 80 minutes, and `cache_audio` of
  # `MyHiFi.Playback.Item` is in it: a person who marked an album would then wait for
  # the read before a note of it reached the card. A queue of its own holds the pictures
  # to one at a time and leaves everything else as it was.
  #
  # **Oban makes no job of this worker unique.** A list of addresses is unique only
  # against the same list in the same order, which says nothing about the address that
  # matters. `MyHiFi.Artwork.ensure/1` holds that rule instead: it asks for no address
  # that the cache holds and for no address that a job of this queue already names.
  use Oban.Worker, queue: :artwork, max_attempts: 3

  require Logger

  alias MyHiFi.Artwork
  alias MyHiFi.Event
  alias MyHiFi.Event.Player, as: Events

  # How many addresses one job reads at one time. A read is network, and a board that
  # waits for one server can wait for four. The thumbnails are made one at a time
  # whatever this is, so this number is about the network alone.
  @at_once 4

  # How long one address has. A picture is 4 MB at most, and a server that answers
  # slower than this holds a job of a queue that runs one at a time.
  @timeout :timer.seconds(30)

  # **The picture of the track that plays goes before a read of a library.** Oban runs
  # the lower number first, and 0 is the first of them.
  @asked_priority 0
  @bulk_priority 1

  @doc """
  The number of addresses that one job of this worker holds.

  `MyHiFi.Artwork.ensure/1` reads it to cut a list into jobs.
  """
  @spec batch_size() :: pos_integer()
  def batch_size, do: 100

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    args
    |> addresses()
    |> read()
    |> answer(args["announce"])
  end

  @doc """
  Ask for one picture, unless the cache has it.

  `announce?` says whether the job tells the `:player` topic that the picture arrived.
  The player asks for the logo of the track that it starts, and it passes `true`. Every
  other caller leaves it alone, and `MyHiFi.Artwork.ensure/1` is what a list of
  pictures calls. See the moduledoc.
  """
  @spec enqueue(String.t() | nil, boolean()) :: :ok
  def enqueue(url, announce? \\ false)

  def enqueue(url, announce?) when is_binary(url) and url != "" do
    if Artwork.readable?(url) and is_nil(Artwork.name(url)) do
      %{"urls" => [url], "announce" => announce?}
      |> new(priority: priority(announce?))
      |> Oban.insert()
    end

    :ok
  end

  def enqueue(_url, _announce?), do: :ok

  @doc """
  The jobs for a list of addresses, in one statement.

  `MyHiFi.Artwork.ensure/1` takes the addresses that the cache does not hold and that
  no job already names, and it gives them here. A list of 4,000 addresses becomes 40
  jobs and one insert, where 4,000 jobs cost the card 4,000 writes.
  """
  @spec enqueue_all([String.t()]) :: :ok
  def enqueue_all([]), do: :ok

  def enqueue_all(urls) do
    urls
    |> Enum.chunk_every(batch_size())
    |> Enum.map(&new(%{"urls" => &1, "announce" => false}, priority: @bulk_priority))
    |> Oban.insert_all()

    :ok
  end

  @doc """
  The addresses that one job of this queue names.

  `MyHiFi.Artwork.ensure/1` reads this of each job that waits, so a read of a library
  asks a second time for none of what the first read already asked for.
  """
  @spec addresses(map()) :: [String.t()]
  def addresses(%{"urls" => urls}) when is_list(urls), do: urls
  def addresses(%{"url" => url}) when is_binary(url), do: [url]
  def addresses(_args), do: []

  # **A whole list reads together, and the thumbnails follow one at a time.** A picture
  # that another job of this queue already stored costs nothing here, because
  # `MyHiFi.Artwork.fetch/1` answers such an address from the cache.
  defp read(urls) do
    urls
    |> Task.async_stream(&Artwork.fetch/1,
      max_concurrency: @at_once,
      timeout: @timeout,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.map(&result/1)
    |> Enum.map(&thumbnail_of/1)
  end

  defp result({:ok, answer}), do: answer
  defp result({:exit, :timeout}), do: {:error, :timeout}
  defp result({:exit, reason}), do: {:error, reason}

  defp thumbnail_of({:ok, name}) do
    generate_thumbnail(name)

    {:ok, name}
  end

  defp thumbnail_of(other), do: other

  # **One address that can never hold a picture stops no other address.** A list of a
  # library holds a few of those, and a job that cancelled for one of them would leave
  # the rest of its list unread. A fault that may come right gives a retry of the job,
  # and every address that already arrived is then a read of the cache.
  defp answer(results, announce?) do
    Enum.each(results, &log/1)

    case Enum.find(results, &retry?/1) do
      nil ->
        announce(results, announce?)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry?({:error, {:status, status}}) when status in 400..499, do: false
  defp retry?({:error, {:not_an_image, _type}}), do: false
  defp retry?({:error, {:too_large, _bytes}}), do: false
  defp retry?({:error, :no_address}), do: false
  defp retry?({:error, _reason}), do: true
  defp retry?({:ok, _name}), do: false

  # A station with no image cannot start to hold one, and an address with no scheme can
  # never hold a picture. Radio Browser sends the text `"null"` for 4 of the 247 New
  # Zealand stations.
  defp log({:error, {:not_an_image, type}}),
    do: Logger.info("An address gave #{inspect(type)} and not an image.")

  defp log({:error, {:too_large, bytes}}),
    do: Logger.info("An address gave #{bytes} bytes, and that is too large for a logo.")

  defp log(_result), do: :ok

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

  # The player asks for one address and it asks for an answer, so a job that announces
  # holds one picture and this names that one. A list of a library announces nothing.
  defp announce([{:ok, name}], true),
    do: Event.publish(:player, %Events.MetadataChanged{artwork_path: "/artwork/#{name}"})

  defp announce(_results, _announce?), do: :ok

  defp priority(true), do: @asked_priority
  defp priority(_announce?), do: @bulk_priority
end
