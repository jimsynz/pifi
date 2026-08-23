defmodule MyHiFi.PlayerFinishTest do
  @moduledoc """
  What the player does when a track reaches its end.

  A station comes back, and a track is over. This is the difference that a podcast
  needs, and `live?` of the playable decides it.
  """

  use MyHiFi.DataCase, async: false

  alias MyHiFi.Event
  alias MyHiFi.Event.Player, as: Events
  alias MyHiFi.Player
  alias MyHiFi.Test.EndingPipeline

  defmodule Recorder do
    @moduledoc """
    A source that writes down what the player tells it.

    The player must call `finished/1` for a track that ends, and `store_position/2`
    for one that a person stops. This keeps each call in the application
    environment, because the player is another process.
    """

    @behaviour MyHiFi.Source

    @impl MyHiFi.Source
    def title, do: "Recorder"

    @impl MyHiFi.Source
    def icon, do: :library

    @impl MyHiFi.Source
    def root, do: :root

    @impl MyHiFi.Source
    def browse(:root, _options), do: {:ok, %{entries: [{:track, track()}], cursor: nil}}

    @impl MyHiFi.Source
    def search(_query, _options), do: {:error, :not_supported}

    @impl MyHiFi.Source
    def track(:only), do: {:ok, track()}

    @impl MyHiFi.Source
    def resolve(:only) do
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
    def favourite(_ref, _true?), do: {:error, :not_supported}

    @impl MyHiFi.Source
    def store_position(ref, position_ms) do
      record({:store_position, ref, position_ms})
    end

    @impl MyHiFi.Source
    def finished(ref), do: record({:finished, ref})

    @impl MyHiFi.Source
    def ref_to_string(:only), do: {:ok, "only"}

    @impl MyHiFi.Source
    def ref_from_string("only"), do: {:ok, :only}
    def ref_from_string(_name), do: {:error, :not_a_name}

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

    defp track do
      %{
        ref: :only,
        title: "One episode",
        subtitle: nil,
        artwork: nil,
        duration_ms: 600_000,
        favourite?: nil
      }
    end
  end

  setup do
    EndingPipeline.use_it()
    Application.put_env(:my_hi_fi, :sources, [Recorder])
    Recorder.forget()
    Recorder.live!(false)
    Recorder.begins_at!(0)
    Event.subscribe(:player)

    on_exit(fn ->
      Player.stop()

      for key <- [:sources, :recorder_live?, :recorder_position_ms, :recorder_calls] do
        Application.delete_env(:my_hi_fi, key)
      end
    end)

    :ok
  end

  describe "a track that reaches its end" do
    test "the player stops, and it does not start the track again" do
      assert :ok = Player.play(Recorder, :only)

      # Every play publishes this once, before there is anything to hear.
      assert_receive %Events.Buffering{}, 2000
      assert_receive %Events.Started{}, 2000
      assert_receive %Events.Stopped{reason: :finished}, 2000

      # A restart would publish a second one. The track is over, so nothing does.
      refute_receive %Events.Buffering{}, 500

      assert %{playing?: false} = Player.state()
    end

    test "it tells the source that the track ended" do
      assert :ok = Player.play(Recorder, :only)
      assert_receive %Events.Stopped{reason: :finished}, 2000

      assert {:finished, :only} in Recorder.calls()
    end

    test "it writes no place for a track that ended" do
      assert :ok = Player.play(Recorder, :only)
      assert_receive %Events.Stopped{reason: :finished}, 2000

      # The source marks the episode played, and that returns the place to the
      # start. A place written here would fight with that.
      refute Enum.any?(Recorder.calls(), &match?({:store_position, _ref, _ms}, &1))
    end

    test "it keeps the track for a person to see" do
      assert :ok = Player.play(Recorder, :only)
      assert_receive %Events.Stopped{reason: :finished}, 2000

      # `MyHiFi.Player` holds the source and the ref, so leaving standby plays this
      # again. It holds no track, because nothing plays.
      assert %{track: nil, playing?: false} = Player.state()
    end
  end

  describe "a live stream that ends" do
    test "the player starts it again" do
      Recorder.live!(true)

      assert :ok = Player.play(Recorder, :only)

      assert_receive %Events.Buffering{}, 2000
      assert_receive %Events.Started{live?: true}, 2000

      # A live stream that ends is a fault of the network, and a person expects the
      # music to come back. The second `Buffering` is that restart.
      assert_receive %Events.Buffering{}, 2000

      refute_received %Events.Stopped{reason: :finished}
    end

    test "it tells the source no place, because a live stream holds none" do
      Recorder.live!(true)

      assert :ok = Player.play(Recorder, :only)
      assert_receive %Events.Buffering{}, 2000
      assert_receive %Events.Started{}, 2000
      assert_receive %Events.Buffering{}, 2000

      refute Enum.any?(Recorder.calls(), &match?({:finished, _ref}, &1))
    end
  end

  describe "the place inside a track" do
    test "a stop writes where the person stopped" do
      Recorder.live!(true)

      assert :ok = Player.play(Recorder, :only)
      assert_receive %Events.Started{}, 2000

      assert :ok = Player.stop()

      assert [{:store_position, :only, position_ms}] =
               Enum.filter(Recorder.calls(), &match?({:store_position, _ref, _ms}, &1))

      assert position_ms >= 0
    end

    test "standby writes where the person stopped" do
      Recorder.live!(true)

      assert :ok = Player.play(Recorder, :only)
      assert_receive %Events.Started{}, 2000

      assert :ok = Player.standby(true)

      assert Enum.any?(Recorder.calls(), &match?({:store_position, :only, _ms}, &1))

      Player.standby(false)
    end

    test "a resume counts from where the stream began" do
      Recorder.live!(true)
      Recorder.begins_at!(300_000)

      assert :ok = Player.play(Recorder, :only)
      assert_receive %Events.Started{}, 2000

      # The stream holds the bytes from 5 minutes in, so the place in the whole
      # track is 5 minutes and not the time since the audio began.
      assert %{position_ms: position_ms} = Player.state()
      assert position_ms >= 300_000
      assert position_ms < 305_000
    end

    test "a track that never began writes no place" do
      # Nothing played, so there is no place, and writing 0 would lose the place
      # that the person already had.
      assert :ok = Player.stop()

      assert Recorder.calls() == []
    end
  end
end
