defmodule PiFi.Playback.Queue.Walk do
  @moduledoc """
  Which row comes next, and which came before.

  `PiFi.Playback.Queue.Move`, `PiFi.Playback.Queue.Advance` and
  `PiFi.Playback.Queue.NextUp` all ask that question, and they used to answer it each
  by reading `position + 1`. Shuffle and repeat are both answers to the same question,
  so the three ask this instead and none of them holds a rule of its own.

  ## The column depends on the mode and nothing else

  A shuffled queue walks `shuffle_position` and an ordinary one walks `position`. The
  rows are the same rows either way: a shuffle deals a second column and moves nothing.
  See `PiFi.Playback.Queue.Shuffle`.

  **A shuffled queue with a row that was never dealt falls back to the plain order.**
  That row would otherwise be unreachable, and a queue that skips a track a person added
  is worse than one that plays in the wrong order for a moment.
  """

  alias PiFi.Playback.Queue
  alias PiFi.Playback.Queue.Mode

  @doc """
  The row that follows the one that plays.

  `repeating?` says whether this is a track that ended, in which case a repeat of one
  gives the same row back. A person who pressed next asked for a different track, so
  that press passes `false`. See `PiFi.Playback.Queue.Mode`.
  """
  @spec after_playing(boolean()) :: {:ok, Queue.t()} | {:error, :no_more}
  def after_playing(repeating?) do
    with {:ok, playing} <- playing() do
      step_from(playing, 1, repeating? and Mode.repeat() == :one)
    end
  end

  @doc "The row before the one that plays. A repeat of one has no meaning here."
  @spec before_playing() :: {:ok, Queue.t()} | {:error, :no_more}
  def before_playing do
    with {:ok, playing} <- playing(), do: step_from(playing, -1, false)
  end

  @doc """
  The row that the player is playing, or `{:error, :no_more}` for a queue with none.
  """
  @spec playing() :: {:ok, Queue.t()} | {:error, :no_more}
  def playing do
    case Ash.read_one!(Ash.Query.for_read(Queue, :playing)) do
      nil -> {:error, :no_more}
      row -> {:ok, row}
    end
  end

  @doc """
  The order that the queue plays in, first to last.

  A page draws the order that a person made, and this is the order that they hear.
  """
  @spec in_play_order() :: [Queue.t()]
  def in_play_order do
    rows = Ash.read!(Queue)

    if shuffled?(rows) do
      Enum.sort_by(rows, & &1.shuffle_position)
    else
      Enum.sort_by(rows, & &1.position)
    end
  end

  # A repeat of one gives back the row that is playing, and the caller wanted it anyway.
  defp step_from(_playing, _step, true), do: playing()

  defp step_from(playing, step, false) do
    rows = in_play_order()

    case Enum.find_index(rows, &(&1.id == playing.id)) do
      nil -> {:error, :no_more}
      index -> beside(rows, index + step, step)
    end
  end

  # **The bounds are checked and `Enum.at/3` is not asked to.** It reads a negative
  # index from the end of the list, so a step back from the first row would give the
  # last one and call it the one before.
  defp beside(rows, wanted, step) do
    if wanted in 0..(length(rows) - 1)//1 do
      {:ok, Enum.at(rows, wanted)}
    else
      wrapped(rows, step)
    end
  end

  # Only a repeat of all wraps. A repeat of one has already been answered above, and it
  # means nothing for a person pressing next.
  defp wrapped(rows, step) do
    case Mode.repeat() do
      :all -> {:ok, end_of(rows, step)}
      _off_or_one -> {:error, :no_more}
    end
  end

  defp end_of(rows, 1), do: List.first(rows)
  defp end_of(rows, -1), do: List.last(rows)

  # **A row that no shuffle dealt has no place in that order**, and walking a column
  # that some rows do not hold would skip them. See the module documentation.
  defp shuffled?(rows) do
    Mode.shuffle?() and rows != [] and Enum.all?(rows, &is_integer(&1.shuffle_position))
  end
end
