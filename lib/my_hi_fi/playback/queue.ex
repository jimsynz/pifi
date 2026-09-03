defmodule MyHiFi.Playback.Queue do
  @moduledoc """
  What plays now, and what plays next.

  Each row names one `MyHiFi.Playback.Item` and its place in the order. One row holds
  `playing?`, and that is the track that the player has.

  ## Why ETS, and what a restart does

  A queue changes with each press of a control, and the database is on an SD card. ETS
  writes nothing to the card, so a person who moves through a list wears nothing out.

  **A restart therefore empties the queue.** A device that starts plays nothing until a
  person asks. Standby is not a restart: it stops the audio and keeps the machine, so
  the queue lives through it.

  ## It holds an identifier, and not a relationship

  `item_id` is a plain attribute. An item lives in SQLite and a queue row lives in ETS,
  and Ash cannot join two data layers. A caller that wants the item reads it with
  `MyHiFi.Playback.get_item/1`.

  ## The order

  `position` counts from 0. `replace` and `append` write it for a new row, and
  `MyHiFi.Playback.Queue.Order` writes it again when a row goes. A caller therefore
  cannot make two rows of one place, and it cannot leave a gap.
  """

  use Ash.Resource,
    otp_app: :my_hi_fi,
    domain: MyHiFi.Playback,
    data_layer: Ash.DataLayer.Ets

  # The player and the web interface read one queue, so the table is not private. A
  # private table belongs to the process that made it, and each test would then see a
  # queue of its own while the player saw another.
  ets do
    table :playback_queue
    private? false
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
      description "The one row that the player has. It gives nothing for an empty queue."
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

      run MyHiFi.Playback.Queue.Replace
    end

    action :append, {:array, :struct} do
      description "Add items after the last one. It marks nothing."

      constraints items: [instance_of: __MODULE__]

      argument :item_ids, {:array, :uuid}, allow_nil?: false

      run MyHiFi.Playback.Queue.Append
    end

    action :move, :struct do
      description """
      Move the mark to the row before or after the one that plays.

      It gives `{:error, :no_more}` at each end of the list, and for a queue that no
      row holds.
      """

      constraints instance_of: __MODULE__

      argument :direction, :atom, allow_nil?: false, constraints: [one_of: [:next, :previous]]

      run MyHiFi.Playback.Queue.Move
    end

    action :remove, :struct do
      description """
      Take one row out, and close the gap that it leaves.

      It does not move the mark. See `MyHiFi.Playback.Queue.Remove`.
      """

      constraints instance_of: __MODULE__

      argument :id, :uuid, allow_nil?: false

      run MyHiFi.Playback.Queue.Remove
    end

    action :next_up, :struct do
      description """
      The row after the one that plays, and this moves no mark.

      `MyHiFi.Player` reads the audio of the next track before the current one ends,
      so it must know which row that is without playing it. `:move` cannot answer,
      because it moves the mark and a person in the middle of a track has not asked
      for the next one yet.

      It gives `{:error, :no_more}` at the end of the list, and for a queue that no
      row holds, in the way that `:move` does.
      """

      constraints instance_of: __MODULE__

      run MyHiFi.Playback.Queue.NextUp
    end

    action :clear, :integer do
      description "Empty the queue, and give the number of rows that went."

      run fn _input, _context ->
        rows = Ash.read!(__MODULE__)
        Enum.each(rows, &Ash.destroy!/1)

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

      `MyHiFi.Playback.Queue.Order` is the only caller, because a place that one write
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

    attribute :item_id, :uuid do
      description "The `MyHiFi.Playback.Item` that this row names."
      allow_nil? false
      public? true
    end

    attribute :position, :integer do
      description "Where it comes in the order. It counts from 0."
      allow_nil? false
      public? true
    end

    attribute :playing?, :boolean do
      description "The player has this row."
      source :playing
      allow_nil? false
      default false
      public? true
    end
  end
end
