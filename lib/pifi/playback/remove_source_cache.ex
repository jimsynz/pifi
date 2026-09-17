defmodule PiFi.Playback.RemoveSourceCache do
  @moduledoc """
  Removes what the cache holds for one source, in a job.

  A person presses one control, and the control answers at once. The removal reads the
  items of the source and deletes a file for each entry, and a library names thousands
  of them, so the player must not wait for it.

  **A job and not a task, because this device stops often.** It goes into standby, a
  person takes the power away, and a new firmware restarts it. A task that stopped in
  the middle would leave the rest of the files on the card for ever, and nothing would
  ask for them again: the source is out of use, so no page and no schedule reads it.
  Oban gives the work back to the queue instead.

  `PiFi.Player` asks for this when a source goes out of use. See
  `PiFi.Playback.Item.RemoveCache` for what goes and what stays.
  """

  # One job for one source. A person who presses the control twice asks for one
  # removal, and the second job would read a cache that the first one emptied.
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:source],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Logger

  alias PiFi.Playback
  alias PiFi.Source

  @doc """
  Ask for the cache of one source to go.

  It answers at once, and it raises nothing: a queue that refuses the job must not
  stop a person from taking a source out of use.
  """
  @spec ask(module()) :: :ok
  def ask(module) do
    case Oban.insert(new(%{source: Source.slug(module)})) do
      {:ok, _job} -> :ok
      {:error, reason} -> Logger.warning("Could not ask for the cache to go: #{inspect(reason)}")
    end

    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source" => slug}}) do
    removed = Playback.remove_source_cache!(slug)

    Logger.info("#{removed} entries of the cache of #{slug} went.")

    :ok
  end
end
