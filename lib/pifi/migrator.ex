defmodule PiFi.Migrator do
  @moduledoc """
  Brings the database up to date.

  No person runs `mix ash.setup` on a device, so the firmware migrates itself.
  `PiFi.Application` calls `migrate/0` before it starts the supervision tree,
  because Oban reads its own tables when it starts.
  """

  require Logger

  @doc """
  Run each migration that is pending.

  `Ecto.Migrator.with_repo/2` starts the repo, and the SQLite adapter creates the
  database file when it connects. Nothing else needs to make the file.

  It carries over the database of the former name of the product first. See
  `carry_over/0`.
  """
  @spec migrate() :: :ok
  def migrate do
    carry_over()

    {:ok, _result, _apps} =
      Ecto.Migrator.with_repo(PiFi.Repo, &Ecto.Migrator.run(&1, :up, all: true))

    :ok
  end

  # The database of the firmware that was called MyHiFi.
  @former "/root/my_hi_fi.db"

  # The journal and the shared memory of SQLite sit beside the database. A clean stop
  # removes them, and this device stops when a person takes the power away, so a board
  # can hold both. **The journal carries writes that the database file does not**, so a
  # move of the database alone would lose the last of them.
  @sidecars ["-wal", "-shm"]

  @doc """
  Move the database of the former name of the product to the name it has now.

  The product was called MyHiFi, and a board that ran that firmware holds
  `/root/my_hi_fi.db`. The adapter makes an empty database when it finds no file, so a
  firmware that only looked for the new name would give a person an empty catalogue,
  no settings and no favourites, and the old file would sit beside it unread.

  **It moves nothing when the new database is already there.** That is the normal case
  after the first boot, and a move then would throw away what the device has done
  since.
  """
  @spec carry_over() :: :ok
  def carry_over do
    former = former()
    database = Application.get_env(:pifi, PiFi.Repo)[:database]

    if is_binary(database) and File.exists?(former) and not File.exists?(database) do
      for suffix <- ["" | @sidecars], File.exists?(former <> suffix) do
        File.rename!(former <> suffix, database <> suffix)
      end

      Logger.info("The database moved from #{former} to #{database}.")
    end

    :ok
  end

  @doc "Where the firmware that was called MyHiFi kept the database."
  @spec former() :: String.t()
  def former, do: Application.get_env(:pifi, :former_database, @former)
end
