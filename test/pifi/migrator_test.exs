defmodule PiFi.MigratorTest do
  @moduledoc """
  The database of a board that ran the firmware when it was called MyHiFi.

  The test writes files and reads where they went. It starts no repo, because
  `carry_over/0` runs before one opens and that is the whole point of it.
  """

  use ExUnit.Case, async: false

  alias PiFi.Migrator

  setup do
    directory = Path.join(System.tmp_dir!(), "carry_over_#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)

    former = Path.join(directory, "my_hi_fi.db")
    database = Path.join(directory, "pifi.db")

    repo = Application.get_env(:pifi, PiFi.Repo)
    Application.put_env(:pifi, PiFi.Repo, Keyword.put(repo, :database, database))
    Application.put_env(:pifi, :former_database, former)

    on_exit(fn ->
      Application.put_env(:pifi, PiFi.Repo, repo)
      Application.delete_env(:pifi, :former_database)
      File.rm_rf(directory)
    end)

    {:ok, former: former, database: database}
  end

  describe "carry_over/0" do
    test "it moves the database of the former name", %{former: former, database: database} do
      File.write!(former, "the catalogue of a person")

      assert :ok = Migrator.carry_over()

      assert File.read!(database) == "the catalogue of a person"
      refute File.exists?(former)
    end

    # **The journal carries writes that the database file does not.** This device stops
    # when a person takes the power away, so a board can hold one, and a move of the
    # database alone would lose the last writes of the firmware before it.
    test "it takes the journal and the shared memory with it", %{
      former: former,
      database: database
    } do
      File.write!(former, "the catalogue")
      File.write!(former <> "-wal", "the writes that are not in the file yet")
      File.write!(former <> "-shm", "the shared memory")

      assert :ok = Migrator.carry_over()

      assert File.read!(database <> "-wal") == "the writes that are not in the file yet"
      assert File.read!(database <> "-shm") == "the shared memory"
      refute File.exists?(former <> "-wal")
      refute File.exists?(former <> "-shm")
    end

    # A database with no journal beside it is the normal case after a clean stop.
    test "a journal that is absent is not an error", %{former: former, database: database} do
      File.write!(former, "the catalogue")

      assert :ok = Migrator.carry_over()

      assert File.exists?(database)
      refute File.exists?(database <> "-wal")
    end

    # **This is every boot after the first one.** A move then would throw away what the
    # device has done since.
    test "it moves nothing when the database is already there", %{
      former: former,
      database: database
    } do
      File.write!(former, "what the device held before")
      File.write!(database, "what the device holds now")

      assert :ok = Migrator.carry_over()

      assert File.read!(database) == "what the device holds now"
      assert File.read!(former) == "what the device held before"
    end

    test "a device that never ran the former firmware is untouched", %{database: database} do
      assert :ok = Migrator.carry_over()

      refute File.exists?(database)
    end
  end
end
