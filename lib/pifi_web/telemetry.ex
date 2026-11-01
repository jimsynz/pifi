defmodule PiFiWeb.Telemetry do
  @moduledoc """
  Telemetry supervision and metrics for the development dashboard at `/dev/dashboard`.

  Metrics cover source resolution, time to first sound, skips, and track playback.
  """

  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),
      summary("pifi.player.resolve.stop.duration",
        tags: [:source],
        tag_values: &source_name/1,
        unit: {:native, :millisecond}
      ),
      summary("pifi.player.sound.duration",
        tags: [:source, :live?],
        tag_values: &source_name/1,
        unit: {:native, :millisecond}
      ),
      summary("pifi.player.gap.duration",
        unit: {:native, :millisecond}
      ),
      summary("pifi.player.skip.stop.duration",
        tags: [:direction],
        unit: {:native, :millisecond}
      ),
      summary("pifi.player.skip.stop.moved_ms",
        tags: [:direction],
        measurement: &skip_distance/2,
        unit: :millisecond
      ),
      summary("pifi.player.track.duration",
        tags: [:reason, :source],
        tag_values: &source_name/1,
        unit: :millisecond
      ),
      counter("pifi.player.track.duration",
        tags: [:reason, :source],
        tag_values: &source_name/1
      )
    ]
  end

  defp source_name(%{source: nil} = metadata), do: %{metadata | source: "none"}

  defp source_name(%{source: source} = metadata), do: %{metadata | source: source.title()}

  defp source_name(metadata), do: metadata

  defp skip_distance(_measurements, metadata), do: Map.get(metadata, :moved_ms, 0)

  defp periodic_measurements do
    []
  end
end
