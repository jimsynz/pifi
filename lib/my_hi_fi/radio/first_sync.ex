defmodule MyHiFi.Radio.FirstSync do
  @moduledoc """
  Fills the catalogue with stations at the first start of a device.

  The weekly schedule of `MyHiFi.Radio.Sync` keeps the list current, and it
  first runs at the end of the week. A new device would hold no station until
  then, so this puts one job in the queue when the catalogue holds none.

  It runs as a task in the supervision tree, after Oban, and it then stops. The
  job goes through Oban, so a device with no network yet gets the retries of the
  queue.
  """

  require Ash.Query
  require Logger

  alias MyHiFi.Playback.Item
  alias MyHiFi.Radio.Sync
  alias MyHiFi.Source

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_argument) do
    %{id: __MODULE__, start: {Task, :start_link, [&run/0]}, restart: :temporary}
  end

  @doc """
  Put one sync job in the queue when the catalogue holds no station.
  """
  @spec run() :: :ok
  def run do
    if held() == 0 do
      Logger.info("No stations yet. Asking for the list of each chosen country.")
      AshOban.schedule(Sync, :sync_from_remote)
    end

    :ok
  end

  defp held do
    Item
    |> Ash.Query.filter(source == ^Source.slug(Source.InternetRadio))
    |> Ash.count!()
  end
end
