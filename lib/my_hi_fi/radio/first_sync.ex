defmodule MyHiFi.Radio.FirstSync do
  @moduledoc """
  Fills the station table at the first start of a device.

  The weekly schedule of `MyHiFi.Radio.Station` keeps the list current, and it
  first runs at the end of the week. A new device would hold no station until
  then, so this puts one job in the queue when the table is empty.

  It runs as a task in the supervision tree, after Oban, and it then stops. The
  job goes through Oban, so a device with no network yet gets the retries of the
  queue.
  """

  require Logger

  alias MyHiFi.Radio
  alias MyHiFi.Radio.Station

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_argument) do
    %{id: __MODULE__, start: {Task, :start_link, [&run/0]}, restart: :temporary}
  end

  @doc """
  Put one sync job in the queue when the station table holds nothing.
  """
  @spec run() :: :ok
  def run do
    case Radio.list_stations!(query: [limit: 1]) do
      [] ->
        Logger.info("No stations yet. Asking for the list of each chosen country.")
        AshOban.schedule(Station, :sync_from_remote)
        :ok

      [_station | _rest] ->
        :ok
    end
  end
end
