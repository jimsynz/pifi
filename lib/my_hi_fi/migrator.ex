defmodule MyHiFi.Migrator do
  @moduledoc """
  Brings the database up to date.

  A device has nobody to run `mix ash.setup`, so the firmware migrates itself.
  `MyHiFi.Application` calls `migrate/0` before it starts the supervision tree,
  because Oban queries its own tables as soon as it starts.
  """

  @doc """
  Run each migration that is pending.

  `Ecto.Migrator.with_repo/2` starts the repo, and the SQLite adapter creates the
  database file when it connects. Nothing else needs to make the file.
  """
  @spec migrate() :: :ok
  def migrate do
    {:ok, _result, _apps} =
      Ecto.Migrator.with_repo(MyHiFi.Repo, &Ecto.Migrator.run(&1, :up, all: true))

    :ok
  end
end
