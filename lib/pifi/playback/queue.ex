defmodule PiFi.Playback.Queue do
  @moduledoc """
  What plays now, and what plays next.

  Each row identifies one `PiFi.Playback.Item` and its place in the order. One row
  carries `playing?`, and that row is the track that the player is playing.

  ## The queue lives through a restart

  **A reboot or a firmware upgrade leaves the queue where it was**, and the marked row
  comes back with it. `PiFi.Player` reads that row when it starts and selects the track
  without playing it, so a person reads what they were listening to and presses play.
  Standby keeps the machine, so it never touched the queue in the first place.

  This was on ETS, to spare the SD card the writes. The wear argument did not hold up:
  a press writes a handful of rows and a replace writes one batch of at most the length
  of a list, which is nothing beside the podcast episodes that this device writes to the
  same card. A queue that a power cut emptied was the real cost.

  ## The order

  `position` counts from 0. `replace` and `append` write it for a new row, and
  `PiFi.Playback.Queue.Order` writes it again when a row goes. A caller therefore
  cannot make two rows of one place, and it cannot leave a gap.
  """

  use Ash.Resource,
    otp_app: :pifi,
    domain: PiFi.Playback,
    data_layer: AshSqlite.DataLayer

  alias PiFi.Playback.Item

  sqlite do
    table "playback_queue"
    repo PiFi.Repo

    references do
      reference :item, on_delete: :delete
    end
  end

  actions do
    default_accept []

    # The primary read holds no preparation of its own, because every load of a
    # relationship and every lookup of one row uses it. `in_order` is the one that a
    # person reads.
    defaults [:read]

    read :in_order do
      description "The whole queue, in the order that it plays."
      prepare build(sort: [position: :asc])
    end

    read :playing do
      description "The one row that the player is playing. It returns nothing for an empty queue."
      filter expr(playing? == true)
      get? true
    end

    action :replace, {:array, :struct} do
      description """
      Put a new list in the queue, and mark one row of it.

      `item_ids` is the order that a person sees. `playing_index` is the row that they
      pressed, and it becomes the track that plays.
      """

      constraints items: [instance_of: __MODULE__]

      argument :item_ids, {:array, :uuid}, allow_nil?: false
      argument :playing_index, :integer, allow_nil?: false, default: 0

      run PiFi.Playback.Queue.Replace
    end

    action :append, {:array, :struct} do
      description "Add items after the last one. It marks nothing."

      constraints items: [instance_of: __MODULE__]

      argument :item_ids, {:array, :uuid}, allow_nil?: false

      run PiFi.Playback.Queue.Append
    end

    action :move, :struct do
      description """
      Move the mark to the row before or after the one that plays.

      It returns `{:error, :no_more}` at each end of the list, and for an empty queue.
      """

      constraints instance_of: __MODULE__

      argument :direction, :atom, allow_nil?: false, constraints: [one_of: [:next, :previous]]

      run PiFi.Playback.Queue.Move
    end

    action :remove, :struct do
      description """
      Take one row out, and close the gap that it leaves.

      It does not move the mark. See `PiFi.Playback.Queue.Remove`.
      """

      constraints instance_of: __MODULE__

      argument :id, :uuid, allow_nil?: false

      run PiFi.Playback.Queue.Remove
    end

    action :reorder, :struct do
      description """
      Move one row to another position, and renumber the rest around it.

      `position` counts from 0. A position outside the queue is clamped to the nearest
      end, so a drag above the first row leaves it where it is. This does not change
      which row is playing. See `PiFi.Playback.Queue.Reorder`.
      """

      constraints instance_of: __MODULE__

      argument :id, :uuid, allow_nil?: false
      argument :position, :integer, allow_nil?: false

      run PiFi.Playback.Queue.Reorder
    end

    action :next_up, :struct do
      description """
      The row after the one that plays. It moves no mark.

      `PiFi.Player` reads the audio of the next track before the current one ends,
      so it must know which row that is without playing it. `:move` cannot answer,
      because it moves the mark and a person in the middle of a track has not asked
      for the next one yet.

      It returns `{:error, :no_more}` at the end of the list, and for an empty queue,
      in the way that `:move` does.
      """

      constraints instance_of: __MODULE__

      run PiFi.Playback.Queue.NextUp
    end

    action :clear, :integer do
      description "Empty the queue. It returns the number of rows that it removed."

      run fn _input, _context ->
        %{status: :success, records: rows} =
          Ash.bulk_destroy!(__MODULE__, :destroy, %{}, return_records?: true)

        {:ok, length(rows)}
      end
    end

    create :create do
      accept [:item_id, :position, :playing?]
    end

    update :set_playing do
      description "Mark this row, or take the mark off it."
      accept [:playing?]
    end

    update :set_position do
      description """
      Move this row to another place.

      `PiFi.Playback.Queue.Order` is the only caller, because a place that one write
      changes by itself makes a gap or two rows of one place.
      """

      accept [:position]
    end

    destroy :destroy do
      primary? true
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :position, :integer do
      description "Where it comes in the order. It counts from 0."
      allow_nil? false
      public? true
    end

    attribute :playing?, :boolean do
      description "The player is playing this row."
      source :playing
      allow_nil? false
      default false
      public? true
    end
  end

  # **A sync that drops a track takes its queue row with it.** A row used to carry a
  # plain identifier, because an item was in SQLite and a queue row was in ETS and Ash
  # joins no two data layers. Both are in SQLite now, so one query draws a whole queue
  # with the title and the artwork of each row, and a row that names nothing cannot
  # survive a restart.
  relationships do
    belongs_to :item, Item do
      description "The `PiFi.Playback.Item` that this row plays."
      allow_nil? false
      attribute_public? true
      public? true
    end
  end
end
