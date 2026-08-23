defmodule MyHiFi.Podcast.Refresh do
  @moduledoc """
  Reads the feed of one show and writes what it holds.

  Two callers need this, and they must not disagree. `MyHiFi.Source.Podcasts` reads
  a feed when a person opens a show whose local copy is old, and
  `MyHiFi.Podcast.Show.RefreshAll` reads the feed of each subscribed show on a
  schedule.

  A read that fails writes `last_error` and leaves the episodes alone. A person with
  no network still sees what they had, and a page can say why there is nothing
  newer.
  """

  require Logger

  alias MyHiFi.Podcast
  alias MyHiFi.Podcast.Feed

  # A person with a knob moves through a list, and no person moves through 2955
  # episodes. One feed of the measurement holds that many. The database is on an SD
  # card, so the rest go.
  @keep 200

  @doc "How many episodes of one show a device keeps."
  @spec keep() :: pos_integer()
  def keep, do: @keep

  @doc """
  Read the feed of one show.

  It gives the show as it now stands, whether the read succeeded or not, so a
  caller can list the episodes either way.
  """
  @spec run(MyHiFi.Podcast.Show.t()) :: MyHiFi.Podcast.Show.t()
  def run(show) do
    case Feed.read(show.feed_url, max_items: @keep) do
      {:ok, %{show: attrs, episodes: episodes}} ->
        {:ok, show} = Podcast.upsert_show_from_feed(Map.put(attrs, :feed_url, show.feed_url))
        Enum.each(episodes, &Podcast.upsert_episode_from_feed!(Map.put(&1, :show_id, show.id)))
        prune(show)
        show

      {:error, reason} ->
        Logger.warning("Could not read #{show.feed_url}: #{inspect(reason)}")
        {:ok, show} = Podcast.record_show_error(show, %{last_error: inspect(reason)})
        show
    end
  end

  @doc """
  Remove the episodes of one show past the newest #{@keep}.

  A feed that drops an old episode leaves the row behind, and a publisher who
  writes one each day adds a row each day. Neither one should fill the card.

  The place of a person goes with the episode. An episode that a feed no longer
  holds cannot play, so there is nothing to keep a place in.
  """
  @spec prune(MyHiFi.Podcast.Show.t()) :: :ok
  def prune(show) do
    show.id
    |> Podcast.episodes_of_show!()
    |> Enum.drop(@keep)
    |> Enum.each(&Podcast.destroy_episode!/1)
  end
end
