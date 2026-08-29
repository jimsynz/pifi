defmodule MyHiFi.PlayerFinishTest do
  @moduledoc """
  What the player does when a track reaches its end.

  A station comes back, and a track is over. This is the difference that a podcast
  needs, and `live?` of the playable decides it.
  """

  use MyHiFi.DataCase, async: false

  alias MyHiFi.Event
  alias MyHiFi.Event.Player, as: Events
  alias MyHiFi.Playback
  alias MyHiFi.Player
  alias MyHiFi.Test.EndingPipeline

  defmodule Recorder do
    @moduledoc """
    A source of one track, and a note of what the player told it.

    `MyHiFi.Player` writes the place and the played mark on to the item itself, so the
    tests read the catalogue for those. This source records `finished/1` alone, which
    is the one thing that a source still hears about the end of a track.
    """

    @behaviour MyHiFi.Source

    alias MyHiFi.Playback

    @slug "recorder"

    @impl MyHiFi.Source
    def title, do: "Recorder"

    # This source is one that the player uses, and no page browses it.
    @impl MyHiFi.Source
    def kinds, do: [track: "Tracks"]

    @impl MyHiFi.Source
    def roots, do: []

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
         live?: live?(),
         position_ms: position_ms()
       }}
    end

    @impl MyHiFi.Source
    def finished(item), do: record({:finished, item.id})

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

    @doc "Say whether the next resolve gives a live stream."
    def live!(live?), do: Application.put_env(:my_hi_fi, :recorder_live?, live?)

    @doc "Say where the next resolve begins."
    def begins_at!(position_ms) do
      Application.put_env(:my_hi_fi, :recorder_position_ms, position_ms)
    end

    @doc "Everything that the player has said, oldest first."
    def calls, do: Enum.reverse(Application.get_env(:my_hi_fi, :recorder_calls, []))

    def forget, do: Application.delete_env(:my_hi_fi, :recorder_calls)

    defp live?, do: Application.get_env(:my_hi_fi, :recorder_live?, false)

    defp position_ms, do: Application.get_env(:my_hi_fi, :recorder_position_ms, 0)

    defp record(call) do
      calls = Application.get_env(:my_hi_fi, :recorder_calls, [])
      Application.put_env(:my_hi_fi, :recorder_calls, [call | calls])
      :ok
    end
  end

  defp play_it do
    one = Recorder.episode()
    assert {:ok, :ok} = Playback.play([one.id])

    one
  end

  setup do
    EndingPipeline.use_it()
    Playback.clear_queue!()
    Application.put_env(:my_hi_fi, :sources, [Recorder])
    Recorder.forget()
    Recorder.live!(false)
    Recorder.begins_at!(0)
    Event.subscribe(:player)

    on_exit(fn ->
      Player.stop()
      Playback.clear_queue!()

      for key <- [:sources, :recorder_live?, :recorder_position_ms, :recorder_calls] do
        Application.delete_env(:my_hi_fi, key)
      end
    end)

    :ok
  end

  describe "a track that reaches its end" do
    test "the player stops, and it does not start the track again" do
      one = play_it()

      # Every play publishes this once, before there is anything to hear.
      assert_receive %Events.Buffering{}, 2000
      assert_receive %Events.Started{}, 2000
      assert_receive %Events.Stopped{reason: :finished}, 2000

      # A restart would publish a second one. The track is over, so nothing does.
      refute_receive %Events.Buffering{}, 500

      assert %{playing?: false} = Player.state()
    end

    test "it marks the item played, and it tells the source" do
      one = play_it()
      assert_receive %Events.Stopped{reason: :finished}, 2000

      assert {:finished, one.id} in Recorder.calls()
      assert Playback.get_item!(one.id).played? == true
    end

    test "it writes no place for a track that ended" do
      one = play_it()
      assert_receive %Events.Stopped{reason: :finished}, 2000

      # The played mark returns the place to the start, and a place written here would
      # fight with that.
      assert Playback.get_item!(one.id).position_ms == 0
    end

    # The queue holds one row, so there is nothing after it. A person reads what they
    # heard last, and a play control starts it again.
    test "it keeps the track for a person to see" do
      one = play_it()
      assert_receive %Events.Stopped{reason: :finished}, 2000

      assert %{item: %{id: id}, playing?: false} = Player.state()
      assert id == one.id
    end
  end

  describe "a live stream that ends" do
    test "the player starts it again" do
      Recorder.live!(true)

      one = play_it()

      assert_receive %Events.Buffering{}, 2000
      assert_receive %Events.Started{live?: true}, 2000

      # A live stream that ends is a fault of the network, and a person expects the
      # music to come back. The second `Buffering` is that restart.
      assert_receive %Events.Buffering{}, 2000

      refute_received %Events.Stopped{reason: :finished}
    end

    test "it tells the source no place, because a live stream holds none" do
      Recorder.live!(true)

      one = play_it()
      assert_receive %Events.Buffering{}, 2000
      assert_receive %Events.Started{}, 2000
      assert_receive %Events.Buffering{}, 2000

      refute Enum.any?(Recorder.calls(), &match?({:finished, _id}, &1))
      refute Playback.get_item!(one.id).played?
    end
  end

  describe "the place inside a track" do
    test "a stop writes where the person stopped" do
      Recorder.live!(true)

      one = play_it()
      assert_receive %Events.Started{}, 2000

      assert :ok = Player.stop()

      # A live stream holds no byte count, so `position_bytes` stays nil and the time
      # is what says that the place was written.
      assert %{position_ms: position_ms} = Playback.get_item!(one.id)
      assert position_ms >= 0
    end

    test "standby writes where the person stopped" do
      Recorder.live!(true)

      one = play_it()
      assert_receive %Events.Started{}, 2000

      assert :ok = Player.standby(true)

      assert Playback.get_item!(one.id).position_ms >= 0

      Player.standby(false)
    end

    test "a resume counts from where the stream began" do
      Recorder.live!(true)
      Recorder.begins_at!(300_000)

      one = play_it()
      assert_receive %Events.Started{}, 2000

      # The stream holds the bytes from 5 minutes in, so the place in the whole
      # track is 5 minutes and not the time since the audio began.
      assert %{position_ms: position_ms} = Player.state()
      assert position_ms >= 300_000
      assert position_ms < 305_000
    end

    test "a track that never began writes no place" do
      # Nothing played, so there is no place, and writing 0 would lose the place that
      # the person already had. `position_bytes` is nil until a write.
      one = Recorder.episode()

      assert :ok = Player.stop()

      assert Playback.get_item!(one.id).position_bytes == nil
    end
  end
end
