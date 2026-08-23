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

  alias MyHiFi.Podcast
  alias MyHiFi.Podcast.Refresh

  @stale_after_days 7

  @doc "How long a show that no person subscribed to stays."
  @spec stale_after_days() :: pos_integer()
  def stale_after_days, do: @stale_after_days

  @impl true
  def run(_input, _options, _context) do
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

    {:ok, %{read: read.ok, failed: read.failed, removed: removed}}
  end

  defp remove_forgotten do
    before = DateTime.add(DateTime.utc_now(), -@stale_after_days, :day)

    Podcast.list_shows!()
    |> Enum.reject(& &1.subscribed?)
    |> Enum.filter(&(DateTime.compare(&1.updated_at, before) == :lt))
    |> Enum.map(&remove/1)
    |> Enum.count(&(&1 == :ok))
  end

  defp remove(show) do
    show.id
    |> Podcast.episodes_of_show!()
    |> Enum.each(&Podcast.destroy_episode!/1)

    Podcast.destroy_show(show)
  end
end
