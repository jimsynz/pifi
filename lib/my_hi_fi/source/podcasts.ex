defmodule MyHiFi.Source.Podcasts do
  @moduledoc """
  Podcasts, from the Podcast Index and from the feed of each publisher.

  The tree has three branches under the root.

      Subscriptions       the shows that a person subscribed to
        a show            the episodes of that show
      Trending            the shows that are popular now
      Categories          one container for each category of the index
        History           the popular shows of that category

  A show is a container and an episode is a track, so `favourite/2` on a show
  subscribes to it. See the `container` type of `MyHiFi.Source`.

  ## The two services

  The index finds a show, and it gives no episode. The feed of the publisher gives
  the episodes. `MyHiFi.Podcast.Feed` reads it, and a private feed therefore works
  even though the index does not hold it.

  A branch that needs the index gives `{:error, :no_api_key}` for a device that
  holds no key. `Subscriptions` needs no key, so a person who subscribed keeps
  every show without one.

  ## What a search writes

  A search and the trending list write a `MyHiFi.Podcast.Show` for each answer, so
  a `ref` is `{:show, id}` in every branch, in the same way that internet radio
  names `{:station, id}`. A row also holds the title and the artwork of a show that
  a person looked at once, and it holds `index_id` for a later call to the index.

  The cost is a row for each answer of each search. A row is small, and a device
  serves one household. A job removes an old show that no person subscribed to. See
  section 4 of `docs/podcasts-plan.md`.
  """

  @behaviour MyHiFi.Source

  alias MyHiFi.Player.Download
  alias MyHiFi.Podcast
  alias MyHiFi.Podcast.Index
  alias MyHiFi.Podcast.Refresh

  @default_limit 100

  # A feed changes when a publisher writes an episode, and no publisher writes one
  # each minute. An hour is short enough that a person who opens a show twice in a
  # day sees the new episode, and long enough that moving through the tree reads no
  # feed twice.
  @stale_after_seconds 3600

  @impl MyHiFi.Source
  def title, do: "Podcasts"

  @impl MyHiFi.Source
  def icon, do: :podcast

  @impl MyHiFi.Source
  def root, do: :root

  @impl MyHiFi.Source
  def browse(ref, options \\ [])

  def browse(:root, _options) do
    {:ok,
     page([
       {:container,
        %{ref: :subscriptions, title: "Subscriptions", artwork: nil, favourite?: nil}},
       {:container, %{ref: :trending, title: "Trending", artwork: nil, favourite?: nil}},
       {:container, %{ref: :categories, title: "Categories", artwork: nil, favourite?: nil}}
     ])}
  end

  def browse(:subscriptions, options) do
    {:ok, shows(Podcast.subscribed_shows!(), options)}
  end

  def browse(:trending, options) do
    with {:ok, found} <- Index.trending(limit: limit(options)) do
      {:ok, shows(store(found), options)}
    end
  end

  def browse(:categories, options) do
    with {:ok, categories} <- Index.categories() do
      containers =
        Enum.map(
          categories,
          &{:container,
           %{ref: {:category, &1.name}, title: &1.name, artwork: nil, favourite?: nil}}
        )

      {:ok, paginate(containers, options)}
    end
  end

  def browse({:category, name}, options) do
    with {:ok, found} <- Index.trending(category: name, limit: limit(options)) do
      {:ok, shows(store(found), options)}
    end
  end

  def browse({:show, id}, options) do
    with {:ok, show} <- Podcast.get_show(id) do
      show = refresh_if_stale(show)

      {:ok, tracks(Podcast.episodes_of_show!(show.id), show, options)}
    end
  end

  def browse(ref, _options), do: {:error, {:no_such_container, ref}}

  @impl MyHiFi.Source
  def search(query, options \\ []) do
    with {:ok, found} <- Index.search(query, limit: limit(options)) do
      {:ok, shows(store(found), options)}
    end
  end

  @impl MyHiFi.Source
  def track({:episode, id}) do
    with {:ok, episode} <- Podcast.get_episode(id, load: [:show]) do
      {:ok, to_track(episode, episode.show)}
    end
  end

  def track(ref), do: {:error, {:not_a_track, ref}}

  @impl MyHiFi.Source
  def resolve({:episode, id}) do
    with {:ok, episode} <- Podcast.get_episode(id), do: playable(episode)
  end

  def resolve(ref), do: {:error, {:not_a_track, ref}}

  @impl MyHiFi.Source
  def favourite({:show, id}, true?) do
    with {:ok, show} <- Podcast.get_show(id),
         {:ok, _show} <- mark(show, true?) do
      :ok
    end
  end

  def favourite(ref, _true?), do: {:error, {:not_a_show, ref}}

  @impl MyHiFi.Source
  def store_position({:episode, id}, %{ms: ms, bytes: bytes}) do
    with {:ok, episode} <- Podcast.get_episode(id),
         {:ok, _episode} <-
           Podcast.store_position(episode, %{position_ms: ms, position_bytes: bytes}) do
      :ok
    end
  end

  def store_position(_ref, _place), do: :ok

  @impl MyHiFi.Source
  def finished({:episode, id}) do
    with {:ok, episode} <- Podcast.get_episode(id),
         {:ok, _episode} <- Podcast.mark_played(episode) do
      # The file held `keep?` while the person was in the middle of it. They reached
      # the end, so an eviction may take it now.
      Download.release(id)
    end
  end

  def finished(_ref), do: :ok

  # An episode holds a UUID, and a UUID holds no colon. A container needs no name,
  # because the player stores the tracks only. See `MyHiFi.Source.ref_to_string/1`.
  @impl MyHiFi.Source
  def ref_to_string({:episode, id}), do: {:ok, "episode:" <> id}

  def ref_to_string(_ref), do: {:error, :cannot_name}

  @impl MyHiFi.Source
  def ref_from_string("episode:" <> id) do
    case Ash.Type.cast_input(Ash.Type.UUID, id) do
      {:ok, id} when is_binary(id) -> {:ok, {:episode, id}}
      _other -> {:error, :not_a_name}
    end
  end

  def ref_from_string(_name), do: {:error, :not_a_name}

  # The feed of the publisher decides what the episodes are, so this reads it when
  # the local copy is old. A read that fails keeps the episodes that the device
  # already holds: a person with no network still sees what they had, and
  # `last_error` says why there is nothing newer.
  defp refresh_if_stale(show) do
    if stale?(show), do: refresh(show), else: show
  end

  defp stale?(%{last_fetched_at: nil}), do: true

  defp stale?(%{last_fetched_at: fetched_at}) do
    DateTime.diff(DateTime.utc_now(), fetched_at, :second) > @stale_after_seconds
  end

  # `MyHiFi.Podcast.Refresh` holds this, because the job that runs on a schedule
  # must read a feed in the same way that a person opening a show does.
  defp refresh(show), do: Refresh.run(show)

  # The index gives a show, and a row gives it a `ref` that survives a restart.
  defp store(found), do: Enum.map(found, &Podcast.upsert_show_from_index!/1)

  defp playable(episode) do
    case format(episode.mime_type) do
      nil ->
        {:error, {:unsupported_format, episode.mime_type}}

      format ->
        {:ok,
         %{
           uri: episode.audio_url,
           headers: [],
           transport: :download,
           container: :none,
           format: format,
           live?: false,
           position_ms: episode.position_ms,
           key: episode.id,
           position_bytes: episode.position_bytes || 0
         }}
    end
  end

  # 8771 of the 8773 episodes of the measurement hold `audio/mpeg`, and 2 hold
  # `audio/x-m4a`. MP4 needs a demultiplexer that this firmware does not hold, so
  # an m4a episode gives an error and a person reads the reason. See section 9 of
  # `docs/podcasts-plan.md`.
  defp format("audio/mpeg"), do: :mp3
  defp format("audio/mp3"), do: :mp3
  defp format("audio/mpeg3"), do: :mp3
  defp format("audio/x-mpeg"), do: :mp3
  defp format("audio/aac"), do: :aac
  defp format("audio/aacp"), do: :aac
  defp format(_other), do: nil

  defp mark(show, true), do: Podcast.subscribe(show)
  defp mark(show, false), do: Podcast.unsubscribe(show)

  defp shows(shows, options) do
    shows
    |> Enum.map(&{:container, to_container(&1)})
    |> paginate(options)
  end

  defp to_container(show) do
    %{
      ref: {:show, show.id},
      title: show.title,
      artwork: show.artwork_url,
      favourite?: show.subscribed?
    }
  end

  defp tracks(episodes, show, options) do
    episodes
    |> Enum.map(&{:track, to_track(&1, show)})
    |> paginate(options)
  end

  defp to_track(episode, show) do
    %{
      ref: {:episode, episode.id},
      title: episode.title || "An episode",
      subtitle: subtitle(episode),
      # A publisher writes artwork for the episode of 70% of the measurement. The
      # cover of the show serves the rest, so every episode holds a picture.
      artwork: episode.artwork_url || artwork_of(show),
      duration_ms: episode.duration_ms,
      # An episode carries no mark. A person subscribes to the show, which is the
      # container, and `favourite?` there holds that.
      favourite?: nil
    }
  end

  defp artwork_of(%{artwork_url: url}), do: url
  defp artwork_of(_show), do: nil

  # The date tells a person which episode is new, and the length tells them whether
  # they have time for it.
  defp subtitle(%{published_at: nil, duration_ms: nil}), do: nil
  defp subtitle(%{published_at: nil, duration_ms: duration}), do: minutes(duration)
  defp subtitle(%{published_at: at, duration_ms: nil}), do: date(at)

  defp subtitle(%{published_at: at, duration_ms: duration}),
    do: "#{date(at)}, #{minutes(duration)}"

  defp date(at), do: Calendar.strftime(at, "%-d %b %Y")

  defp minutes(duration) do
    case div(duration, 60_000) do
      0 -> "under a minute"
      1 -> "1 min"
      minutes -> "#{minutes} min"
    end
  end

  defp limit(options), do: Keyword.get(options, :limit, @default_limit)

  defp page(entries, cursor \\ nil), do: %{entries: entries, cursor: cursor}

  defp paginate(entries, options) do
    limit = limit(options)
    offset = Keyword.get(options, :cursor, 0)

    taken = entries |> Enum.drop(offset) |> Enum.take(limit)
    next = offset + length(taken)

    if next < length(entries), do: page(taken, next), else: page(taken)
  end
end
