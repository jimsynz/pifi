defmodule PiFi.Playback.QueueModeTest do
  @moduledoc """
  Shuffle and repeat, which are two answers to one question: which row comes next.

  `PiFi.Playback.Queue.Walk` is the one place that decides, so these read the answers
  that `move`, `advance` and `next_up` give rather than the column underneath.
  """

  use PiFi.DataCase, async: false

  doctest PiFi.Playback.Queue.Mode, import: true

  alias PiFi.Playback
  alias PiFi.Playback.Queue
  alias PiFi.Playback.Queue.Mode

  setup do
    on_exit(fn ->
      Mode.put_shuffle(false)
      Mode.put_repeat(:off)
      Playback.clear_queue!()
    end)

    :ok
  end

  defp track(ref) do
    Playback.upsert_item!(%{
      source: "internet-radio",
      source_ref: ref,
      title: "Track #{ref}",
      kind: :track,
      keeps_place?: false
    })
  end

  defp queue_of(count) do
    ids = for n <- 1..count, do: track("t#{n}").id
    {:ok, _rows} = Playback.replace_queue(ids)

    ids
  end

  defp playing_ref do
    {:ok, row} = Playback.queue_playing()
    Playback.get_item!(row.item_id).source_ref
  end

  describe "a device that no person changed" do
    test "plays in order and stops at the end" do
      queue_of(3)

      assert playing_ref() == "t1"
      assert {:ok, _row} = Playback.move_queue(:next)
      assert {:ok, _row} = Playback.move_queue(:next)
      assert playing_ref() == "t3"

      assert {:error, _reason} = Playback.move_queue(:next)
      assert Mode.repeat() == :off
      refute Mode.shuffle?()
    end

    test "cannot step back past the first row" do
      queue_of(3)

      assert {:error, _reason} = Playback.move_queue(:previous)
      assert playing_ref() == "t1"
    end
  end

  describe "repeat all" do
    test "the end of the queue wraps to the start" do
      queue_of(3)
      :ok = Mode.put_repeat(:all)

      Playback.move_queue(:next)
      Playback.move_queue(:next)
      assert playing_ref() == "t3"

      assert {:ok, _row} = Playback.move_queue(:next)
      assert playing_ref() == "t1"
    end

    test "and a step back from the start wraps to the end" do
      queue_of(3)
      :ok = Mode.put_repeat(:all)

      assert {:ok, _row} = Playback.move_queue(:previous)
      assert playing_ref() == "t3"
    end
  end

  # **This is the one place the two presses differ.** Somebody who presses next has
  # asked for a different track, and a control that did nothing would read as a device
  # that stopped listening to them.
  describe "repeat one" do
    test "a track that ends plays again" do
      queue_of(3)
      :ok = Mode.put_repeat(:one)

      assert {:ok, _row} = Playback.advance_queue()
      assert playing_ref() == "t1"
    end

    test "and a person who presses next still moves on" do
      queue_of(3)
      :ok = Mode.put_repeat(:one)

      assert {:ok, _row} = Playback.move_queue(:next)
      assert playing_ref() == "t2"
    end

    test "the prefetch reads what the end of the track will give" do
      queue_of(3)
      :ok = Mode.put_repeat(:one)

      assert {:ok, row} = Playback.queue_next_up()
      assert Playback.get_item!(row.item_id).source_ref == "t1"
    end

    # Rewriting the mark to the row it already names is two writes to the card for no
    # change at all.
    test "it leaves the mark where it is" do
      queue_of(3)
      :ok = Mode.put_repeat(:one)

      {:ok, before} = Playback.queue_playing()
      Playback.advance_queue()
      {:ok, after_it} = Playback.queue_playing()

      assert before.id == after_it.id
    end
  end

  describe "shuffle" do
    # **A shuffle that reordered the rows could not be undone.** This is the whole
    # reason it writes a second column.
    test "leaves the order that a person made where it is" do
      queue_of(6)
      order = Playback.queue!() |> Enum.sort_by(& &1.position) |> Enum.map(& &1.item_id)

      :ok = Mode.put_shuffle(true)

      assert Playback.queue!() |> Enum.sort_by(& &1.position) |> Enum.map(& &1.item_id) ==
               order
    end

    test "gives every row a place" do
      queue_of(6)
      :ok = Mode.put_shuffle(true)

      places = Playback.queue!() |> Enum.map(& &1.shuffle_position) |> Enum.sort()

      assert places == Enum.to_list(0..5)
    end

    # A shuffle must not change what a person is hearing.
    test "leaves the track that is playing playing" do
      queue_of(6)
      assert playing_ref() == "t1"

      :ok = Mode.put_shuffle(true)

      assert playing_ref() == "t1"
      {:ok, row} = Playback.queue_playing()
      assert row.shuffle_position == 0
    end

    test "turning it off plays the order that a person made again" do
      queue_of(4)
      :ok = Mode.put_shuffle(true)
      :ok = Mode.put_shuffle(false)

      assert {:ok, _row} = Playback.move_queue(:next)
      assert playing_ref() == "t2"
    end

    # **A row with no place in the shuffled order is a row the walk never reaches.**
    test "a track added to a shuffled queue is dealt a place" do
      queue_of(3)
      :ok = Mode.put_shuffle(true)

      later = track("t99")
      {:ok, _rows} = Playback.append_to_queue([later.id])

      dealt = Playback.queue!() |> Enum.map(& &1.shuffle_position)

      assert Enum.all?(dealt, &is_integer/1)
      assert length(Enum.uniq(dealt)) == 4
    end

    test "a queue that is replaced is dealt again" do
      queue_of(3)
      :ok = Mode.put_shuffle(true)

      queue_of(5)

      dealt = Playback.queue!() |> Enum.map(& &1.shuffle_position)

      assert Enum.all?(dealt, &is_integer/1)
      assert length(Enum.uniq(dealt)) == 5
    end

    # It reaches every row and no row twice, which an order that repeated or skipped
    # would not.
    test "walking it reaches every track exactly once" do
      queue_of(8)
      :ok = Mode.put_shuffle(true)

      heard = walk_the_whole_queue([playing_ref()])

      assert length(heard) == 8
      assert Enum.sort(heard) == Enum.sort(for n <- 1..8, do: "t#{n}")
    end
  end

  defp walk_the_whole_queue(heard) do
    case Playback.move_queue(:next) do
      {:ok, _row} -> walk_the_whole_queue([playing_ref() | heard])
      {:error, _reason} -> heard
    end
  end

  describe "the mode that a page reads" do
    test "it reports both" do
      assert {:ok, %{shuffle?: false, repeat: :off}} = Playback.queue_mode()

      :ok = Mode.put_shuffle(true)
      :ok = Mode.put_repeat(:all)

      assert {:ok, %{shuffle?: true, repeat: :all}} = Playback.queue_mode()
    end

    test "a mode that PiFi does not know is refused" do
      assert {:error, _reason} = Playback.repeat_queue(:sometimes)
    end
  end
end
