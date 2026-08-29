defmodule MyHiFi.Podcast.Show.RefreshAll do
  @moduledoc """
  Reads the feed of each subscribed show, and removes what no person wants.

  A schedule runs this. It reads the subscribed shows only, so a search that a
  person made once costs the device nothing later.

  A feed of a podcast changes when a publisher writes an episode, and no publisher
  writes one each hour. Six hours is often enough for a person who listens each
  day, and it is 4 reads of each feed in a day.

  ## Why it also removes a show

  A search and the trending list write a row for each answer. Two visits to the
  trending list of the index wrote 201 rows on 2026-08-23, and a person asked for
  none of them. Those rows hold the title and the artwork of a show that a person
  looked at, which is worth keeping for a while and not for ever.

  This removes a show that no person subscribed to and that nothing has touched for
  a week. `updated_at` says when something last touched it, and a search that names
  the same show again moves that date.

  SQLite holds the foreign key, so the episodes of a show go before the show.
  """

  use Ash.Resource.Actions.Implementation

  require Logger

  alias MyHiFi.Playback
  alias MyHiFi.Podcast
  alias MyHiFi.Podcast.Refresh
  alias MyHiFi.Source

  @stale_after_days 7

  @doc "How long a show that no person subscribed to stays."
  @spec stale_after_days() :: pos_integer()
  def stale_after_days, do: @stale_after_days

  # A person who takes the podcast source out of use expects the device to stop
  # reading feeds. See `MyHiFi.Source.enabled?/1`.
  @impl true
  def run(_input, _options, _context) do
    if Source.enabled?(Source.Podcasts) do
      refresh_each_feed()
    else
      {:ok, %{read: 0, failed: 0, removed: 0, skipped?: true}}
    end
  end

  defp refresh_each_feed do
    subscribed = Podcast.subscribed_shows!()

    read =
      Enum.reduce(subscribed, %{ok: 0, failed: 0}, fn show, acc ->
        case Refresh.run(show) do
          %{last_error: nil} -> %{acc | ok: acc.ok + 1}
          _show -> %{acc | failed: acc.failed + 1}
        end
      end)

    removed = remove_forgotten()

    Logger.info(
      "Podcast refresh read #{read.ok} feeds, #{read.failed} failed, and removed #{removed} shows."
    )

    {:ok, %{read: read.ok, failed: read.failed, removed: removed, skipped?: false}}
  end

  defp remove_forgotten do
    before = DateTime.add(DateTime.utc_now(), -@stale_after_days, :day)

    Podcast.list_shows!(load: [:item])
    |> Enum.reject(&subscribed?/1)
    |> Enum.filter(&(DateTime.compare(&1.updated_at, before) == :lt))
    |> Enum.map(&remove/1)
    |> Enum.count(&(&1 == :ok))
  end

  # A subscription is a mark on the item of the show. A show that names no item is one
  # that no person has reached, so no person subscribed to it.
  defp subscribed?(%{item: %{favourite?: true}}), do: true
  defp subscribed?(_show), do: false

  # The item of the show holds its episodes, and SQLite removes a child with its
  # parent, so one destroy takes the whole show away.
  # The row of the show names the item, so the show goes first. SQLite holds that key,
  # and it refuses an item that a show still names.
  defp remove(show) do
    result = Podcast.destroy_show(show)
    remove_item(show.item)

    result
  end

  defp remove_item(nil), do: :ok
  defp remove_item(item), do: Playback.destroy_item!(item)
end
