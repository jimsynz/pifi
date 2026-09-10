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
  serves one household. A job removes an old show that no person subscribed to.
  """

  @behaviour MyHiFi.Source

  require Ash.Query
  require Logger

  alias MyHiFi.Playback.Facet
  alias MyHiFi.Playback.Item
  alias MyHiFi.Podcast
  alias MyHiFi.Podcast.Fill
  alias MyHiFi.Podcast.Index
  alias MyHiFi.Podcast.Refresh
  alias MyHiFi.Podcast.Show
  alias MyHiFi.Podcast.Trending
  alias MyHiFi.Settings

  # The index answers with the shows that match best first, and a person who looks for a
  # show by its name finds it near the top. More than this is a list that no person
  # reads.
  @search_limit 50
  @source "podcasts"

  # **How many of the newest episodes of a followed show the card holds.** A person
  # sets it. Three is what a person listens to in a week of commuting, and an episode of
  # 50 MB puts twenty shows at 150 episodes and about 7 GB, which a 30 GB card holds.
  @hold_setting "podcasts.hold_episodes"
  @hold_default 3

  # An episode of 50 MB and a ceiling of 20 is a gigabyte for one show, which is the
  # most that a person can ask for by mistake.
  @hold_ceiling 20

  @impl MyHiFi.Source
  def title, do: "Podcasts"

  @impl MyHiFi.Source
  def icon, do: :podcast

  # An episode is a file on the disk, so a person can move inside it.
  # `MyHiFi.Player.Skip` reads MP3 frames, and 8771 of the 8773 episodes of the
  # measurement hold `audio/mpeg`.
  @impl MyHiFi.Source
  def capabilities, do: [:refresh, :search, :skip]

  @impl MyHiFi.Source
  def kinds, do: [container: "Shows", track: "Episodes"]

  @impl MyHiFi.Source
  # The index gives the categories of each show that it names, so a device learns them
  # from the reads that it already makes and asks for no list of its own. A person sees
  # the categories of the shows that the device holds.
  def roots do
    [
      {"Subscriptions", %{query: subscriptions_query(), kind: :item}},
      {"Trending",
       %{query: Trending.query(), kind: :item, order: Trending.order(), facts: [:subtitle]}},
      {"Categories",
       %{query: Ash.Query.for_read(Facet, :by_key, %{key: "category"}), kind: :facet}}
    ]
  end

  defp subscriptions_query do
    Item
    |> Ash.Query.filter(source == ^@source and kind == :container and favourite? == true)
    |> Ash.Query.sort(sorted_title: :asc)
  end

  @doc """
  A show holds its episodes with the newest one first, and a category holds the
  trending shows.

  **A person opening a show wants the episode of this week**, and a feed of a daily
  programme holds 200 of them. The control that the page draws for this order flips it,
  so a person who starts a series from the start presses one thing.

  An episode says its number when the publisher gives one, its date, and how much of it
  is left. `remaining_ms` is the whole duration for an episode that no person began, so
  a row reads the same way whether they began it or not, and an episode of an unknown
  length draws no time at all.
  """
  @impl MyHiFi.Source
  def listing(nil),
    do: %{facts: [:subtitle], sort: [rank: :desc, sorted_title: :asc], order: Trending.order()}

  def listing(_item) do
    %{
      number?: true,
      facts: [:published_at, :remaining_ms],
      sort: [published_at: :desc],
      order: {"Date", "published_at"}
    }
  end

  # A person opening a show whose local copy is old must not wait for the network, so
  # the read goes to a job. See `read_feed_if_needed/1`.
  @impl MyHiFi.Source
  # It runs for its effect, and the behaviour asks for `:ok`. `read_feed_if_needed/1`
  # gives the show, or the job, or nothing at all, and no caller reads any of that.
  def opened(item) do
    read_feed_if_needed(item)

    :ok
  end

  @impl MyHiFi.Source
  # `opened/1` reads a feed whose local copy is old, and the schedule reads each one
  # every six hours. A person who knows that a publisher wrote an episode a moment ago
  # waits for neither, so this reads it whatever the age of the copy.
  def refresh(item) do
    with {:ok, show} <- show_of(item) do
      read_feed_behind(show)

      :ok
    end
  end

  @impl MyHiFi.Source
  # The index holds millions of shows, and this device holds the ones that it has read:
  # the trending list, the subscriptions, and what an earlier search named. A person
  # looks for a show by its name, so this asks the index and writes what it names. The
  # query then finds it.
  #
  # It gives the shows and the episodes. A person looks for a show to subscribe to it,
  # and for an episode of a show that they hold, and `MyHiFiWeb.SearchLive` draws a
  # control to choose between the two. See `c:MyHiFi.Source.kinds/0`.
  def search(text) do
    read_index(text)

    Item
    |> Ash.Query.filter(source == ^@source)
    |> Ash.Query.sort(sorted_title: :asc)
  end

  # A device with no key, and an index that does not answer, both leave the catalogue as
  # it is. A person still gets what the device holds.
  defp read_index(text) do
    case String.trim(text) do
      "" ->
        :ok

      trimmed ->
        case Index.search(trimmed, limit: @search_limit) do
          {:ok, found} -> store(found)
          {:error, _reason} -> :ok
        end
    end
  end

  @impl MyHiFi.Source
  def resolve(%{kind: :track} = item), do: playable(item)

  def resolve(item), do: {:error, {:not_a_track, item.id}}

  @impl MyHiFi.Source
  def settings do
    [
      %{
        key: "key",
        title: "Key",
        description: index_description(),
        link: %{href: "https://api.podcastindex.org/signup", title: "api.podcastindex.org/signup"},
        type: :text,
        value: nil,
        write_only?: true
      },
      %{
        key: "secret",
        title: "Secret",
        description: nil,
        link: nil,
        type: :password,
        value: nil,
        write_only?: true
      },
      %{
        key: "episodes",
        title: "Episodes to hold offline",
        description:
          "A show that you follow keeps this many of its newest episodes on the card, " <>
            "so they play with no network. An episode that you finish gives its room back. " <>
            "0 holds none.",
        link: nil,
        type: :number,
        value: to_string(hold_limit()),
        write_only?: false
      }
    ]
  end

  # A person who changes the key writes both values again, because the page holds
  # neither one. A key with no secret signs nothing, so a half write is no use.
  @impl MyHiFi.Source
  # **Each value stands by itself.** The key and the secret are write only, so the form
  # draws them empty every time, and a person who changed the episode count alone would
  # have had to type both of them again.
  def put_settings(values) do
    with {:ok, index?} <- put_index(values),
         :ok <- put_episodes(values) do
      answer(index?)
    end
  end

  # **The answer names what changed.** `confirmation/0` asks the index whether the key
  # works, which is a request over the network, and a person who changed the number of
  # episodes asked nothing about their key.
  defp answer(true), do: confirmation()

  defp answer(false), do: {:ok, held_confirmation(hold_limit())}

  defp held_confirmation(0), do: "A show that you follow holds no episode on the card."

  defp held_confirmation(1), do: "A show that you follow holds its newest episode."

  defp held_confirmation(count),
    do: "A show that you follow holds its #{count} newest episodes."

  defp put_index(%{"key" => key, "secret" => secret}) do
    case {present(key), present(secret)} do
      {{:ok, key}, {:ok, secret}} ->
        Settings.put!(Index.key_setting(), key)
        Settings.put!(Index.secret_setting(), secret)

        {:ok, true}

      {:error, :error} ->
        {:ok, false}

      _one_of_them ->
        {:error, "Give both the key and the secret."}
    end
  end

  defp put_index(_values), do: {:ok, false}

  defp put_episodes(%{"episodes" => episodes}) do
    case whole(episodes) do
      {:ok, count} ->
        Settings.put!(@hold_setting, to_string(count))

        :ok

      :none ->
        :ok

      :error ->
        {:error, "The number of episodes to hold is a whole number from 0 to #{@hold_ceiling}."}
    end
  end

  defp put_episodes(_values), do: :ok

  # An episode of 50 MB and a ceiling of 20 is a gigabyte for one show, which is the
  # most that a person can ask for by mistake.
  defp whole(text) do
    case present(text) do
      :error ->
        :none

      {:ok, text} ->
        case Integer.parse(String.trim(text)) do
          {count, ""} when count >= 0 and count <= @hold_ceiling -> {:ok, count}
          _other -> :error
        end
    end
  end

  @doc """
  How many of the newest episodes of a followed show the card holds.

  A person sets it, and it is #{@hold_default} until they do. See
  `c:MyHiFi.Source.hold_limit/0`, and `MyHiFi.Playback.FavouriteAudio` for what reads
  it.
  """
  @impl MyHiFi.Source
  def hold_limit do
    case Settings.fetch(@hold_setting) do
      {:ok, %{value: value}} -> whole_or_default(value)
      {:error, _reason} -> @hold_default
    end
  end

  defp whole_or_default(value) do
    case Integer.parse(value) do
      {count, ""} when count >= 0 and count <= @hold_ceiling -> count
      _other -> @hold_default
    end
  end

  # The index signs every request, so a device with no key reaches nothing at all.
  # `MyHiFi.AutoSync` reads this before it asks for the trending list or for a feed.
  @impl MyHiFi.Source
  def ready?, do: Index.configured?()

  @impl MyHiFi.Source
  def settings_actions do
    if Index.configured?() do
      [
        %{
          name: "read_index",
          title: "Read the index again",
          description:
            "Trending comes from the Podcast Index. A read happens each day, and this " <>
              "one happens now.",
          icon: :refresh
        },
        %{
          name: "remove_key",
          title: "Remove the key",
          description: "Your subscriptions stay, and the index finds nothing new.",
          icon: :remove
        }
      ]
    else
      []
    end
  end

  # The read reaches a service, and a person must not wait for it on a settings page.
  # `MyHiFi.Podcast.Trending` publishes `MyHiFi.Event.Source.Changed` when it finishes,
  # and a page that shows Trending reads the list again.
  @impl MyHiFi.Source
  def run_settings_action("read_index") do
    case MyHiFi.Source.ask_for_job(Show, :read_trending) do
      :queued ->
        {:ok, "The device reads the index now. Trending changes when the read finishes."}

      :running ->
        {:ok,
         "The device reads the index already. A read that stopped without finishing " <>
           "starts again within two hours."}
    end
  end

  def run_settings_action("remove_key") do
    for key <- [Index.key_setting(), Index.secret_setting()] do
      case Settings.fetch(key) do
        {:ok, setting} -> Settings.delete!(setting)
        {:error, _reason} -> :ok
      end
    end

    {:ok, "The device holds no key. Your subscriptions stay."}
  end

  def run_settings_action(_name), do: {:error, "Podcasts hold no such control."}

  # The feed of the publisher decides what the episodes are, so a device reads it when
  # the local copy is old. See the `stale?` calculation of `MyHiFi.Podcast.Show`.
  #
  # A show that no read reached holds no episode, and a person who opened one would see
  # an empty list, so that read happens now. Every other read takes seconds while a
  # person waits for a list, so it goes to the job instead. The job publishes
  # `MyHiFi.Event.Source.Changed`, and a page that shows the show reads it again.
  defp read_feed_if_needed(item) do
    case show_of(item) do
      {:ok, %{last_fetched_at: nil} = show} -> Refresh.run(show)
      {:ok, %{stale?: true} = show} -> read_feed_behind(show)
      _other -> :ok
    end
  end

  # A show holds the address of the feed, and the item holds what a person sees. The
  # two meet at `item_id`.
  defp show_of(item) do
    Show
    |> Ash.Query.filter(item_id == ^item.id)
    |> Ash.Query.load([:stale?])
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, {:no_such_show, item.source_ref}}
      other -> other
    end
  end

  # A person asked for a list, and they get it whether the job arrives or not. The
  # schedule reads the same feed each six hours, so a lost job costs a person nothing
  # but the newest episode until then.
  defp read_feed_behind(show) do
    AshOban.run_trigger(show, :refresh)
  rescue
    error ->
      Logger.warning("Could not ask for a read of #{show.feed_url}: #{inspect(error)}")
  end

  # The index gives a show, and a row gives it a `ref` that survives a restart.
  # A row of `MyHiFi.Podcast.Show` holds the feed and the index, and an item holds what
  # a person sees. A search writes both, and it links them.
  defp store(found) do
    Enum.map(found, fn attributes ->
      show = Podcast.upsert_show_from_index!(Map.take(attributes, [:feed_url, :index_id]))
      item = Fill.show(attributes)
      {:ok, _show} = Podcast.set_show_item(show, %{item_id: item.id})

      item
    end)
  end

  # The episodes of `browse/2`, and in the same order, so this list is the list that a
  # person sees. It holds the newest episode first, and it has two ends.
  # `MyHiFi.Podcast.Fill` reads the type of the enclosure, so this holds no mime type to
  # name. The title is what tells a person which episode cannot play.
  # An episode that no read of the feed has filled holds the place of a person and
  # nothing to play. `MyHiFi.Podcast.CarryPlaces` writes one, and the next read of the
  # feed fills it.
  defp playable(%{url: url, format: format} = item) when is_nil(url) or is_nil(format) do
    {:error, {:not_read_yet, item.title}}
  end

  defp playable(%{format: :unknown} = item), do: {:error, {:unsupported_format, item.title}}

  defp playable(item) do
    {:ok,
     %{
       uri: item.url,
       headers: [],
       transport: :download,
       container: :none,
       format: item.format,
       live?: false,
       position_ms: item.position_ms,
       # `MyHiFi.Player.Download` holds the file under this name. It is the identifier
       # of the item now, so a file that an older release wrote is unreachable and the
       # eviction of the cache reclaims it.
       key: item.id,
       position_bytes: item.position_bytes || 0
     }}
  end

  # The subtitle and the picture are columns of the item that `MyHiFi.Podcast.Fill`
  # wrote, so a page draws a list with no join for each row. `artwork` of the item is
  # its own picture, or the cover of the show that holds it.
  # A person learns now whether the key works, and not when a search fails. The
  # category list is the smallest read of the index.
  defp confirmation do
    case Index.categories() do
      {:ok, _categories} ->
        {:ok, "The key works. Podcasts are ready."}

      {:error, :key_refused} ->
        {:error, "The index refused that key. Check both values."}

      {:error, :clock_not_synchronised} ->
        {:ok,
         "The key is stored. The clock of the device is not right yet, so podcasts start working in a moment."}

      {:error, reason} ->
        {:error, "The key is stored, and the index did not answer: #{inspect(reason)}"}
    end
  end

  defp index_description do
    held =
      if Index.configured?(),
        do: "This device has a key.",
        else: "This device has no key."

    "#{held} Podcasts need a key, and a key costs no money. No other device " <>
      "shares it, and your subscriptions play without it."
  end

  defp present(text) do
    case String.trim(text) do
      "" -> :error
      trimmed -> {:ok, trimmed}
    end
  end
end
