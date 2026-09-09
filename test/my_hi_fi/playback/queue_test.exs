defmodule MyHiFi.Playback.QueueTest do
  use MyHiFi.DataCase, async: false

  alias MyHiFi.Playback
  alias MyHiFi.Playback.Queue

  # The table is not private, so it outlives one test in the same way that
  # `MyHiFi.Player` does.
  setup do
    Playback.clear_queue!()
    on_exit(fn -> Playback.clear_queue!() end)
    :ok
  end

  defp item(title) do
    Playback.upsert_item!(%{
      source: "internet-radio",
      source_ref: "station-#{System.unique_integer([:positive])}",
      title: title
    })
  end

  defp titles do
    Playback.queue!()
    |> Enum.map(fn row -> Playback.get_item!(row.item_id).title end)
  end

  defp playing_title do
    case Playback.queue_playing!() do
      nil -> nil
      row -> Playback.get_item!(row.item_id).title
    end
  end

  # **A person will move a row to change what comes next.** The mark stays where it is,
  # because moving a row is not choosing what to listen to. See
  # `MyHiFi.Playback.Queue.Order`.
  describe "moving a row" do
    setup do
      ids = Enum.map(["Alpha", "Bravo", "Charlie", "Delta"], &item(&1).id)
      {:ok, rows} = Playback.replace_queue(ids, %{playing_index: 1})

      %{rows: rows}
    end

    test "a row moves up, and the rest close around it", %{rows: rows} do
      third = Enum.find(rows, &(&1.position == 2))

      assert {:ok, moved} = Playback.reorder_queue(third.id, 1)
      assert moved.position == 1
      assert titles() == ["Alpha", "Charlie", "Bravo", "Delta"]
    end

    test "a row moves down", %{rows: rows} do
      first = Enum.find(rows, &(&1.position == 0))

      assert {:ok, moved} = Playback.reorder_queue(first.id, 2)
      assert moved.position == 2
      assert titles() == ["Bravo", "Charlie", "Alpha", "Delta"]
    end

    test "a row moves to the end", %{rows: rows} do
      first = Enum.find(rows, &(&1.position == 0))

      assert {:ok, _moved} = Playback.reorder_queue(first.id, 3)
      assert titles() == ["Bravo", "Charlie", "Delta", "Alpha"]
    end

    # A person who presses "up" on the first row means the first row, and not an error.
    test "a place outside the queue takes the nearest end", %{rows: rows} do
      first = Enum.find(rows, &(&1.position == 0))
      last = Enum.find(rows, &(&1.position == 3))

      assert {:ok, _moved} = Playback.reorder_queue(first.id, -1)
      assert titles() == ["Alpha", "Bravo", "Charlie", "Delta"]

      assert {:ok, _moved} = Playback.reorder_queue(last.id, 99)
      assert titles() == ["Alpha", "Bravo", "Charlie", "Delta"]
    end

    # **A person who moves a row is still listening to the same track.**
    test "it moves no mark", %{rows: rows} do
      third = Enum.find(rows, &(&1.position == 2))

      assert playing_title() == "Bravo"

      {:ok, _moved} = Playback.reorder_queue(third.id, 0)

      assert playing_title() == "Bravo"
    end

    # The row that plays is a row like any other, and a person may move it.
    test "the row that plays can move, and it keeps the mark", %{rows: rows} do
      playing = Enum.find(rows, &(&1.position == 1))

      assert {:ok, moved} = Playback.reorder_queue(playing.id, 3)
      assert moved.position == 3
      assert moved.playing?
      assert titles() == ["Alpha", "Charlie", "Delta", "Bravo"]
      assert playing_title() == "Bravo"
    end

    test "the places hold no gap after a move", %{rows: rows} do
      third = Enum.find(rows, &(&1.position == 2))

      {:ok, _moved} = Playback.reorder_queue(third.id, 0)

      assert Enum.map(Playback.queue!(), & &1.position) == [0, 1, 2, 3]
    end

    test "a row that is not there gives a reason and moves nothing" do
      assert {:error, _reason} = Playback.reorder_queue(Ash.UUID.generate(), 0)
      assert titles() == ["Alpha", "Bravo", "Charlie", "Delta"]
    end
  end

  describe "putting a list in the queue" do
    test "it holds the order that a person saw" do
      ids = Enum.map(["Alpha", "Bravo", "Charlie"], &item(&1).id)

      assert {:ok, rows} = Playback.replace_queue(ids)
      assert length(rows) == 3
      assert titles() == ["Alpha", "Bravo", "Charlie"]
      assert Enum.map(Playback.queue!(), & &1.position) == [0, 1, 2]
    end

    test "the row that a person pressed is the one that plays" do
      ids = Enum.map(["Alpha", "Bravo", "Charlie"], &item(&1).id)

      assert {:ok, _rows} = Playback.replace_queue(ids, %{playing_index: 1})
      assert playing_title() == "Bravo"
    end

    test "the first row plays when a caller names no place" do
      ids = Enum.map(["Alpha", "Bravo"], &item(&1).id)

      assert {:ok, _rows} = Playback.replace_queue(ids)
      assert playing_title() == "Alpha"
    end

    test "a second list takes the place of the first" do
      Playback.replace_queue!(Enum.map(["Alpha", "Bravo"], &item(&1).id))
      Playback.replace_queue!([item("Delta").id])

      assert titles() == ["Delta"]
      assert playing_title() == "Delta"
    end

    test "an empty list empties the queue" do
      Playback.replace_queue!([item("Alpha").id])

      assert {:ok, []} = Playback.replace_queue([])
      assert titles() == []
      assert Playback.queue_playing!() == nil
    end
  end

  describe "adding to the queue" do
    test "an item goes after the last one, and the mark does not move" do
      Playback.replace_queue!(Enum.map(["Alpha", "Bravo"], &item(&1).id))

      assert {:ok, _rows} = Playback.append_to_queue([item("Charlie").id])

      assert titles() == ["Alpha", "Bravo", "Charlie"]
      assert playing_title() == "Alpha"
    end

    test "it fills an empty queue from the first place" do
      assert {:ok, _rows} = Playback.append_to_queue([item("Alpha").id])

      assert Enum.map(Playback.queue!(), & &1.position) == [0]
      # An append marks nothing, so nothing plays until a caller says so.
      assert Playback.queue_playing!() == nil
    end
  end

  describe "moving through the queue" do
    setup do
      ids = Enum.map(["Alpha", "Bravo", "Charlie"], &item(&1).id)
      Playback.replace_queue!(ids, %{playing_index: 1})
      :ok
    end

    test "next moves the mark to the row after" do
      assert {:ok, row} = Playback.move_queue(:next)
      assert row.playing? == true
      assert playing_title() == "Charlie"
    end

    test "previous moves the mark to the row before" do
      assert {:ok, _row} = Playback.move_queue(:previous)
      assert playing_title() == "Alpha"
    end

    test "one row holds the mark, and never two" do
      Playback.move_queue!(:next)

      assert Playback.queue!() |> Enum.count(& &1.playing?) == 1
    end

    test "the end of the list gives no more" do
      Playback.move_queue!(:next)

      assert {:error, _reason} = Playback.move_queue(:next)
      # The track that plays keeps playing.
      assert playing_title() == "Charlie"
    end

    test "the start of the list gives no more" do
      Playback.move_queue!(:previous)

      assert {:error, _reason} = Playback.move_queue(:previous)
      assert playing_title() == "Alpha"
    end
  end

  describe "a queue that no row holds" do
    test "a move gives no more" do
      assert {:error, _reason} = Playback.move_queue(:next)
      assert {:error, _reason} = Playback.move_queue(:previous)
    end

    test "an append leaves it with no mark, so a move still gives no more" do
      Playback.append_to_queue!([item("Alpha").id])

      assert {:error, _reason} = Playback.move_queue(:next)
    end
  end

  # A person presses the control beside a row. A track that reaches its end stays, so
  # that they can go back to it.
  describe "taking a row out" do
    test "it goes, and the rows below it close the gap" do
      Playback.replace_queue!(Enum.map(["Alpha", "Bravo", "Charlie"], &item(&1).id))
      [_alpha, bravo, _charlie] = Playback.queue!()

      assert {:ok, _row} = Playback.remove_from_queue(bravo.id)

      assert titles() == ["Alpha", "Charlie"]
      assert Enum.map(Playback.queue!(), & &1.position) == [0, 1]
    end

    test "a row that plays keeps the mark until a caller moves it" do
      Playback.replace_queue!(Enum.map(["Alpha", "Bravo"], &item(&1).id))
      [_alpha, bravo] = Playback.queue!()

      Playback.remove_from_queue!(bravo.id)

      assert playing_title() == "Alpha"
    end

    # Only the caller knows what a person meant, so this leaves the queue with no mark
    # and says nothing about what plays.
    test "taking out the row that plays leaves no mark" do
      Playback.replace_queue!(Enum.map(["Alpha", "Bravo"], &item(&1).id))
      [alpha, _bravo] = Playback.queue!()

      Playback.remove_from_queue!(alpha.id)

      assert titles() == ["Bravo"]
      assert Playback.queue_playing!() == nil
    end

    test "a row that no queue holds gives an error" do
      assert {:error, _reason} = Playback.remove_from_queue(Ash.UUID.generate())
    end

    test "the last row goes, and the queue is empty" do
      Playback.replace_queue!([item("Alpha").id])
      [alpha] = Playback.queue!()

      Playback.remove_from_queue!(alpha.id)

      assert Playback.queue!() == []
    end
  end

  describe "emptying the queue" do
    test "it gives the number of rows that went" do
      Playback.replace_queue!(Enum.map(["Alpha", "Bravo"], &item(&1).id))

      assert {:ok, 2} = Playback.clear_queue()
      assert Playback.queue!() == []
    end

    test "an empty queue gives none" do
      assert {:ok, 0} = Playback.clear_queue()
    end
  end

  # ETS holds the queue, and nothing writes it to the card. A restart therefore
  # empties it, and a device plays nothing until a person asks.
  test "the queue is not in the database" do
    Playback.replace_queue!([item("Alpha").id])

    assert Ash.DataLayer.Ets == Ash.DataLayer.data_layer(Queue)
  end
end
