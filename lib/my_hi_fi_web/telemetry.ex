defmodule MyHiFiWeb.Telemetry do
  @moduledoc """
  The metrics that LiveDashboard draws, at `/dev/dashboard`.

  Phoenix writes the endpoint and the VM entries of this list. The player writes the
  rest, and those four answer the questions that a person asks about a stereo that
  feels slow.

  - **`my_hi_fi.player.resolve.stop.duration`** is the time that a source takes to
    turn a row into something playable. It reads a service behind the page, so this
    is the part of the wait that the network of that service owns.
  - **`my_hi_fi.player.sound.duration`** is the time from the press to the first
    sound. It holds the resolve, the first bytes of the download, and the moment that
    `aplay` opens the card.
  - **`my_hi_fi.player.skip.stop.duration`** is the time that a skip reads the disk
    for, and `moved_ms` is how far it landed from where it started.
  - **`my_hi_fi.player.track.duration`** is how long a track sounded, and the reason
    says whether a person stopped it or it reached its end.

  Each one carries the source as a tag, so a station and an episode are separate
  lines. `MyHiFi.Source.title/0` gives the name, because a module name reads as
  `Elixir.MyHiFi.Source.Radio` in the table.

  **The dashboard runs in development alone.** `MyHiFiWeb.Router` mounts it behind
  `dev_routes`, and a firmware of this device is a development build, so the board
  serves it and a production image does not.
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
      summary("my_hi_fi.player.resolve.stop.duration",
        tags: [:source],
        tag_values: &source_name/1,
        unit: {:native, :millisecond}
      ),
      summary("my_hi_fi.player.sound.duration",
        tags: [:source, :live?],
        tag_values: &source_name/1,
        unit: {:native, :millisecond}
      ),
      summary("my_hi_fi.player.skip.stop.duration",
        tags: [:direction],
        unit: {:native, :millisecond}
      ),
      summary("my_hi_fi.player.skip.stop.moved_ms",
        tags: [:direction],
        measurement: &skip_distance/2,
        unit: :millisecond
      ),
      summary("my_hi_fi.player.track.duration",
        tags: [:reason, :source],
        tag_values: &source_name/1,
        unit: :millisecond
      ),
      counter("my_hi_fi.player.track.duration",
        tags: [:reason, :source],
        tag_values: &source_name/1
      )
    ]
  end

  # A module name reads as `Elixir.MyHiFi.Source.Radio` in a table, and a source
  # already says what it is called. A player that names no source gives `nil`, which
  # happens for a track that stops before a source is chosen.
  defp source_name(%{source: nil} = metadata), do: %{metadata | source: "none"}

  defp source_name(%{source: source} = metadata), do: %{metadata | source: source.title()}

  defp source_name(metadata), do: metadata

  # `Telemetry.Metrics` reads a measurement from the measurements, and the distance of
  # a skip is a fact about what happened and not a time, so it rides in the metadata.
  defp skip_distance(_measurements, metadata), do: Map.get(metadata, :moved_ms, 0)

  defp periodic_measurements do
    []
  end
end
