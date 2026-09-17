defmodule PiFi.Repo.Migrations.ConvertMp4Items do
  @moduledoc """
  Give each m4a track of an earlier read the shape that a conversion has.

  **A device that read a Plex library before this firmware cannot read its own
  catalogue after it.** Such a read wrote `mp4` into `container_format`, and
  `PiFi.Playback.Item` no longer names that value, so Ash refuses to load the row:

      cannot load `"mp4"` as type ... one_of: [:none, :mpeg_ts, :ogg]

  One row of that kind stops every query that touches it, so the Albums branch, a
  track listing and the play queue would all fail on a library that held one. A real
  library held 8,800 of them.

  The three columns become what `PiFi.Plex.Fill` writes for such a track now: the
  server converts it, so the codec is unknown, the transport is a playlist, and the
  container is none. The next read of the library writes the same values again, so
  this is a repair and not a rule.
  """

  use Ecto.Migration

  def up do
    execute("""
    UPDATE playback_items
    SET container_format = 'none', format = 'unknown', transport = 'hls'
    WHERE container_format = 'mp4'
    """)
  end

  # **The value that this removed is one that nothing can write now**, so there is
  # nothing to put back. A read of the library gives each row its shape again.
  def down, do: :ok
end
