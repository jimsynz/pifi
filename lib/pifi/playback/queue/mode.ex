defmodule PiFi.Playback.Queue.Mode do
  @moduledoc """
  Whether the queue plays in order, and what happens when it reaches the end.

  Two settings, and both of them are answers to one question: which row comes next.
  `PiFi.Playback.Queue.Move`, `PiFi.Playback.Queue.Advance` and
  `PiFi.Playback.Queue.NextUp` all ask it, and this is the only place that decides.

  ## Shuffle does not move a single row

  **A shuffle that reordered the queue could not be undone.** A person who turned it on,
  listened to half a record and turned it off again would find the record in the order
  the shuffle left it, and the order they made is gone.

  So the rows keep their `position` and gain a `shuffle_position`: a permutation written
  when a person turns shuffle on. The walk reads that column instead, and turning
  shuffle off simply stops reading it. Turning it on again deals a new hand.

  This is also why it survives a restart, in the way that the queue does. A device that
  came back and played the same shuffled order is a device that a person can leave and
  return to.

  ## Repeat, and the one place the two presses differ

  - `:off` — the end of the queue is the end. This is a device that no person changed.
  - `:all` — the end wraps to the start, in whichever order is in use.
  - `:one` — the track plays again.

  **`:one` repeats when a track ends and never when a person presses next.** Somebody
  who presses next has asked for a different track, and a control that did nothing would
  read as a device that had stopped listening to them. `PiFi.Playback.Queue.Advance` is
  the end of a track and honours it; `PiFi.Playback.Queue.Move` is the press and does
  not.
  """

  alias PiFi.Playback.Queue.Shuffle
  alias PiFi.Settings

  @shuffle_key "queue.shuffle"
  @repeat_key "queue.repeat"
  @repeats [:off, :all, :one]

  @typedoc "What happens when the queue reaches its end."
  @type repeat :: :off | :all | :one

  @doc """
  The settings key that says whether the queue is shuffled.

      iex> PiFi.Playback.Queue.Mode.shuffle_key()
      "queue.shuffle"
  """
  @spec shuffle_key() :: String.t()
  def shuffle_key, do: @shuffle_key

  @doc """
  The settings key that holds the repeat mode.

      iex> PiFi.Playback.Queue.Mode.repeat_key()
      "queue.repeat"
  """
  @spec repeat_key() :: String.t()
  def repeat_key, do: @repeat_key

  @doc """
  The repeat modes, in the order that a control steps through them.

      iex> PiFi.Playback.Queue.Mode.repeats()
      [:off, :all, :one]
  """
  @spec repeats() :: [repeat()]
  def repeats, do: @repeats

  @doc "Whether the queue plays in a shuffled order."
  @spec shuffle?() :: boolean()
  def shuffle? do
    case Settings.fetch(@shuffle_key) do
      {:ok, %{value: "true"}} -> true
      _other -> false
    end
  end

  @doc """
  Turn shuffle on, or off.

  Turning it on deals a new order, so a person who turns it off and on again gets a
  different one rather than the same shuffle back.
  """
  @spec put_shuffle(boolean()) :: :ok
  def put_shuffle(shuffle?) do
    Settings.put!(@shuffle_key, to_string(shuffle?))

    if shuffle?, do: Shuffle.deal(), else: :ok
  end

  @doc "What happens when the queue reaches its end."
  @spec repeat() :: repeat()
  def repeat do
    with {:ok, %{value: value}} <- Settings.fetch(@repeat_key),
         mode when mode in @repeats <- safe_atom(value) do
      mode
    else
      _other -> :off
    end
  end

  @doc "Say what happens when the queue reaches its end."
  @spec put_repeat(repeat()) :: :ok | {:error, :no_such_mode}
  def put_repeat(mode) when mode in @repeats do
    Settings.put!(@repeat_key, to_string(mode))

    :ok
  end

  def put_repeat(_mode), do: {:error, :no_such_mode}

  @doc """
  The mode after this one, for a control that a person presses again and again.

      iex> PiFi.Playback.Queue.Mode.after_this(:off)
      :all

      iex> PiFi.Playback.Queue.Mode.after_this(:one)
      :off
  """
  @spec after_this(repeat()) :: repeat()
  def after_this(mode) do
    case Enum.find_index(@repeats, &(&1 == mode)) do
      nil -> :off
      index -> Enum.at(@repeats, rem(index + 1, length(@repeats)))
    end
  end

  # **A setting is text that anything could have written**, and `String.to_atom/1` on
  # such a value grows the atom table without bound. The list above is the whole of what
  # this reads.
  defp safe_atom(value), do: Enum.find(@repeats, &(to_string(&1) == value))
end
