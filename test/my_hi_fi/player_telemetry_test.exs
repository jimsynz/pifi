defmodule MyHiFi.PlayerTelemetryTest do
  @moduledoc """
  What the player measures while it plays.

  `MyHiFiWeb.Telemetry` turns each of these events into a line of LiveDashboard, so
  a name or a key that changes here changes what a person reads there.
  """

  use MyHiFi.DataCase, async: false

  alias MyHiFi.Event
  alias MyHiFi.Event.Player, as: Events
  alias MyHiFi.Playback
  alias MyHiFi.Player
  alias MyHiFi.Test.EndingPipeline
  alias MyHiFi.Test.PlayingPipeline
  alias MyHiFi.Test.SilentOutput

  defmodule Counter do
    @moduledoc """
    A source of one track, for the player to measure.

    `MyHiFi.Test.EndingPipeline` reaches the end of the track by itself, so a test
    that wants the reason `:finished` needs no file and no audio.
    """

    @behaviour MyHiFi.Source

    alias MyHiFi.Playback

    @slug "counter"

    @impl MyHiFi.Source
    def title, do: "Counter"

    @impl MyHiFi.Source
    def kinds, do: [track: "Tracks"]

    @impl MyHiFi.Source
    def roots, do: []

    @impl MyHiFi.Source
    def listing(_item), do: %{sort: :title, direction: :asc, facts: []}

    @impl MyHiFi.Source
    def icon, do: :library

    @impl MyHiFi.Source
    def capabilities, do: [:skip]

    @impl MyHiFi.Source
    def resolve(_item) do
      {:ok,
       %{
         uri: "http://example.test/episode.mp3",
         headers: [],
         transport: :http,
         container: :none,
         format: :mp3,
         live?: false,
         position_ms: 0
       }}
    end

    @doc "The one episode of this source, in the catalogue."
    @spec episode() :: MyHiFi.Playback.Item.t()
    def episode do
      Playback.upsert_item!(%{
        source: @slug,
        source_ref: "only",
        title: "One episode",
        kind: :track,
        duration_ms: 600_000,
        keeps_place?: true
      })
    end
  end

  # Each event goes to the test process, so a test reads what the player wrote and
  # the handler holds no state of its own.
  defp listen(events) do
    handler = "player-telemetry-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach_many(
      handler,
      events,
      fn event, measurements, metadata, _config ->
        send(test, {:measured, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp play_it do
    one = Counter.episode()
    assert {:ok, :ok} = Playback.play([one.id])

    one
  end

  setup do
    EndingPipeline.use_it()
    SilentOutput.use_it()
    Playback.clear_queue!()
    Application.put_env(:my_hi_fi, :sources, [Counter])
    Event.subscribe(:player)

    on_exit(fn ->
      Player.stop()
      Playback.clear_queue!()
      Application.delete_env(:my_hi_fi, :sources)
    end)

    :ok
  end

  describe "the time that a source takes to resolve a row" do
    test "a resolve reports how long it took, and which source did it" do
      listen([[:my_hi_fi, :player, :resolve, :stop]])

      play_it()

      assert_receive {:measured, [:my_hi_fi, :player, :resolve, :stop], measurements, metadata},
                     2000

      assert measurements.duration > 0
      assert metadata.source == Counter
    end
  end

  describe "the time from the press to the first sound" do
    test "the player reports it when the sound begins" do
      listen([[:my_hi_fi, :player, :sound]])

      play_it()

      assert_receive {:measured, [:my_hi_fi, :player, :sound], measurements, metadata}, 2000

      assert measurements.duration > 0
      assert metadata.source == Counter
      assert metadata.live? == false
    end
  end

  describe "how long a track sounded" do
    test "a track that reaches its end gives the reason :finished" do
      listen([[:my_hi_fi, :player, :track]])

      play_it()

      assert_receive {:measured, [:my_hi_fi, :player, :track], measurements, metadata}, 2000

      assert measurements.duration >= 0
      assert metadata.reason == :finished
      assert metadata.source == Counter
    end

    # `MyHiFi.Test.EndingPipeline` reaches the end at once, so a track that a person
    # stops needs the pipeline that keeps playing.
    test "a person who stops a track gives the reason :requested" do
      PlayingPipeline.use_it()
      listen([[:my_hi_fi, :player, :track]])

      play_it()
      assert_receive %Events.Started{}, 2000

      assert :ok = Player.stop()

      assert_receive {:measured, [:my_hi_fi, :player, :track], _measurements,
                      %{reason: :requested}},
                     2000
    end

    # Nothing sounded, so there is nothing to measure. A zero here would say that a
    # person heard a track of no length.
    test "a stop with nothing playing measures nothing" do
      listen([[:my_hi_fi, :player, :track]])

      assert :ok = Player.stop()

      refute_receive {:measured, [:my_hi_fi, :player, :track], _measurements, _metadata}, 500
    end
  end
end
