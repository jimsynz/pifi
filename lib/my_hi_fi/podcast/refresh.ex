defmodule MyHiFi.Podcast.Refresh do
  @moduledoc """
  Reads the feed of one show and writes what it gives.

  Two callers need this, and they must not disagree. `MyHiFi.Source.Podcasts` reads
  a feed when a person opens a show whose local copy is old, and
  `MyHiFi.Podcast.Show.RefreshAll` reads the feed of each subscribed show on a
  schedule.

  A read that fails writes `last_error` and leaves the episodes alone. A person with
  no network still sees what they had, and a page can say why there is nothing
  newer.

  A read that succeeds publishes `MyHiFi.Event.Source.Changed`. Both callers run
  behind the page, so a person can be looking at the episodes of the show while this
  writes newer ones.
  """

  require Ash.Query
  require Logger

  alias MyHiFi.Event
  alias MyHiFi.Playback
  alias MyHiFi.Playback.FavouriteAudio
  alias MyHiFi.Playback.Item
  alias MyHiFi.Podcast
  alias MyHiFi.Podcast.Feed
  alias MyHiFi.Podcast.Fill
  alias MyHiFi.Source

  # A person with a knob moves through a list, and no person moves through 2955
  # episodes. One feed of the measurement has that many. The database is on an SD
  # card, so the rest go.
  @keep 200

  @doc "How many episodes of one show a device keeps."
  @spec keep() :: pos_integer()
  def keep, do: @keep

  @doc """
  Read the feed of one show.

  It returns the show as it now stands, whether the read succeeded or not, so a
  caller can list the episodes either way.
  """
  @spec run(MyHiFi.Podcast.Show.t()) :: MyHiFi.Podcast.Show.t()
  def run(show) do
    case Feed.read(show.feed_url, max_items: @keep) do
      {:ok, %{show: attrs, episodes: episodes}} ->
        # A show carries the address of the feed and what the read gave. The title, the
        # description and the picture go to the item, so this takes what it owns.
        {:ok, show} = Podcast.upsert_show_from_feed(%{feed_url: show.feed_url})
        fill(show, attrs, episodes)
        announce(show)
        show

      {:error, reason} ->
        Logger.warning("Could not read #{show.feed_url}: #{inspect(reason)}")
        {:ok, show} = Podcast.record_show_error(show, %{last_error: inspect(reason)})
        show
    end
  end

  @doc """
  Remove the episodes of one show past the newest #{@keep}.

  A feed that drops an old episode leaves the item behind, and a publisher who writes
  one each day adds an item each day. Neither one should fill the card.

  The place of a person goes with the episode. An episode that a feed no longer names
  cannot play, so there is nothing to keep a place in.
  """
  @spec prune(MyHiFi.Playback.Item.t()) :: :ok
  def prune(item) do
    Item
    |> Ash.Query.filter(parent_id == ^item.id)
    |> Ash.Query.sort(published_at: :desc)
    |> Ash.read!()
    |> Enum.drop(@keep)
    |> Enum.each(&Playback.destroy_item!/1)
  end

  # The catalogue keeps the newest #{@keep} in the same way that `prune/1` does, so a
  # feed that grows leaves nothing behind.
  defp fill(show, attributes, episodes) do
    item = Fill.show(Map.put(attributes, :feed_url, show.feed_url))

    # The show and its item meet at this key. Without it `MyHiFi.Source.Podcasts`
    # cannot find the show behind a container, so it never reads a feed that is old.
    {:ok, _show} = Podcast.set_show_item(show, %{item_id: item.id})

    Fill.episodes(item, show.feed_url, newest(episodes))
    prune(item)
    hold_audio(item)
  end

  # **A new episode of a show that a person follows reads on to the card here.** A mark
  # asks once, and a feed writes an episode a day, so the ask must happen again when the
  # feed changes and this is that moment: `MyHiFi.AutoSync` runs the refresh of the
  # followed shows on a period, and a person who opens a show refreshes it as well.
  #
  # `MyHiFi.Playback.FavouriteAudio` decides how many episodes and which ones, and it
  # reads nothing that the card already keeps.
  defp hold_audio(%{favourite?: true} = item), do: FavouriteAudio.ask(item)

  defp hold_audio(_item), do: :ok

  # An item of a feed can hold no date, and `DateTime.compare/2` refuses a nil. Such an
  # episode is the oldest one, so a person sees the dated ones first.
  defp newest(episodes) do
    episodes
    |> Enum.sort_by(&(&1[:published_at] || ~U[1970-01-01 00:00:00.000000Z]), {:desc, DateTime})
    |> Enum.take(@keep)
  end

  # A read that failed changes no episode, so it announces nothing. `last_error`
  # changed, and a page that shows the reason reads it when a person asks for it.
  defp announce(show) do
    Event.publish(:source, %Event.Source.Changed{
      source: Source.Podcasts,
      ref: {:show, show.id}
    })
  end
end
