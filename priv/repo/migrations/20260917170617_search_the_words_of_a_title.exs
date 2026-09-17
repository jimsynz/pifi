defmodule PiFi.Repo.Migrations.SearchTheWordsOfATitle do
  @moduledoc """
  An FTS5 index of the titles, so a search reads an index and not every row.

  A search matched `instr(lower(title), lower(?))`, and a text in the middle of a
  title needs every row. Over 137,557 items on a board on 2026-09-16 a search for a
  common word took 4.74 s, and the page drew nothing until it answered.

  **The index holds the words of a title, so a search matches the start of a word.**
  A person who types `cell` finds `Celldweller` and stops finding `Excellent`. That is
  the trade, and it is deliberate: the start of a word is what a person means almost
  every time.

  **The table holds no copy of the titles.** `content=` makes it an external content
  index, so the rows stay in `playback_items` and this holds the index alone. That
  costs the card less on every read of a library, and a search joins back by `rowid`.

  **An update writes only when the title changes.** A read of a library upserts every
  row that the server holds, and a trigger without that guard would write the whole
  index again each day for titles that did not move.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE VIRTUAL TABLE playback_items_fts USING fts5(
      title,
      content='playback_items',
      content_rowid='rowid',
      tokenize='unicode61'
    )
    """)

    execute("""
    CREATE TRIGGER playback_items_fts_insert AFTER INSERT ON playback_items BEGIN
      INSERT INTO playback_items_fts(rowid, title) VALUES (new.rowid, new.title);
    END
    """)

    execute("""
    CREATE TRIGGER playback_items_fts_delete AFTER DELETE ON playback_items BEGIN
      INSERT INTO playback_items_fts(playback_items_fts, rowid, title)
      VALUES ('delete', old.rowid, old.title);
    END
    """)

    execute("""
    CREATE TRIGGER playback_items_fts_update AFTER UPDATE OF title ON playback_items
    WHEN new.title IS NOT old.title BEGIN
      INSERT INTO playback_items_fts(playback_items_fts, rowid, title)
      VALUES ('delete', old.rowid, old.title);
      INSERT INTO playback_items_fts(rowid, title) VALUES (new.rowid, new.title);
    END
    """)

    # The rows that the device already holds. `rebuild` reads the content table and
    # writes the whole index, which is what a device that upgrades needs.
    execute("INSERT INTO playback_items_fts(playback_items_fts) VALUES ('rebuild')")
  end

  def down do
    execute("DROP TRIGGER IF EXISTS playback_items_fts_update")
    execute("DROP TRIGGER IF EXISTS playback_items_fts_delete")
    execute("DROP TRIGGER IF EXISTS playback_items_fts_insert")
    execute("DROP TABLE IF EXISTS playback_items_fts")
  end
end
