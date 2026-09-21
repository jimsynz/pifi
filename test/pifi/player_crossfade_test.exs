defmodule PiFi.PlayerCrossfadeTest do
  @moduledoc """
  The end of one track plays under the start of the next.

  The mixing itself lives in `PiFi.Output.Mixer` and `PiFi.Output.APlayPort`, and both
  have tests of their own. These cover what the player decides: when a fade starts, when
  it must not, and what happens to the pipeline underneath.

  `PiFi.Test.PlayingPipeline` answers `{:fade_out, _}` in the way that the sink of an
  ALSA output does, so the player sees a fade that took without a sound card anywhere.
  """

  use PiFi.DataCase, async: false

  alias PiFi.Event
  alias PiFi.Event.Player, as: Events
  alias PiFi.Playback
  alias PiFi.Player
  alias PiFi.Player.Crossfade
  alias PiFi.Test.PlayingPipeline
  alias PiFi.Test.SilentOutput

  defmodule Shelf do
    @moduledoc "A source of short tracks, so a fade begins inside a test."

    @behaviour PiFi.Source

    alias PiFi.Playback

    @slug "shelf"

    @impl PiFi.Source
    def title, do: "Shelf"

    @impl PiFi.Source
    def icon, do: :library

    @impl PiFi.Source
    def capabilities, do: []

    @impl PiFi.Source
    def roots, do: []

    @impl PiFi.Source
    def kinds, do: [track: "Tracks"]

    @impl PiFi.Source
    def resolve(item) do
      {:ok,
       %{
         uri: "http://example.test/#{item.source_ref}.mp3",
         headers: [],
         transport: :http,
         container: :none,
         format: :mp3,
         live?: item.source_ref == "live",
         position_ms: 0
       }}
    end

    @doc "One track of this source, in the catalogue."
    @spec track(String.t()) :: PiFi.Playback.Item.t()
    def track(ref) do
      Playback.upsert_item!(%{
        source: @slug,
        source_ref: ref,
        title: "The #{ref}",
        kind: :track,
        # Shorter than the fade below, so the first progress tick decides.
        duration_ms: 1_500,
        keeps_place?: false
      })
    end
  end

  setup do
    PlayingPipeline.use_it()
    SilentOutput.use_it()
    Playback.clear_queue!()
    Application.put_env(:pifi, :sources, [Shelf])
    Event.subscribe(:player)

    on_exit(fn ->
      Player.stop()
      Crossfade.set_seconds(0)
      Playback.clear_queue!()
      Application.delete_env(:pifi, :sources)
    end)

    :ok
  end

  defp two_tracks do
    first = Shelf.track("first")
    second = Shelf.track("second")
    assert {:ok, _rows} = Playback.replace_queue([first.id, second.id])

    {first, second}
  end

  defp play(item), do: assert(:ok = Player.play(item))

  # The progress tick is what decides, and it runs once a second.
  defp await_crossfade(tries \\ 60)
  defp await_crossfade(0), do: false

  defp await_crossfade(tries) do
    if Player.state().crossfading? do
      true
    else
      Process.sleep(100)
      await_crossfade(tries - 1)
    end
  end

  describe "a fade near the end of a track" do
    setup do
      :ok = Crossfade.set_seconds(3)

      :ok
    end

    test "the next track starts under the one that is ending" do
      {first, second} = two_tracks()
      play(first)

      assert await_crossfade()

      state = Player.state()
      assert state.item.id == second.id
      assert state.crossfading?
    end

    # **The music stopped only when nothing follows it**, and a fade is the strongest
    # case of that: a person can hear both tracks, so a page that said the device had
    # stopped would be reading it wrong.
    test "it says that the music stopped never" do
      {first, _second} = two_tracks()
      play(first)

      assert await_crossfade()

      refute_received %Events.Stopped{}
    end

    test "the queue moves to the track that arrived" do
      {_first, second} = two_tracks()
      play(Shelf.track("first"))

      assert await_crossfade()
      assert {:ok, playing} = Playback.queue_playing()
      assert playing.item_id == second.id
    end

    # A person asked for the track after this one, so finishing a fade into a track that
    # they no longer want is the wrong answer.
    test "a person who presses next in the middle of it leaves one track playing" do
      first = Shelf.track("first")
      second = Shelf.track("second")
      third = Shelf.track("third")
      assert {:ok, _rows} = Playback.replace_queue([first.id, second.id, third.id])

      play(first)

      assert await_crossfade()
      assert :ok = Player.next()

      refute Player.state().crossfading?
    end

    test "a stop leaves nothing playing under it" do
      {first, _second} = two_tracks()
      play(first)

      assert await_crossfade()
      assert :ok = Player.stop()

      refute Player.state().crossfading?
    end
  end

  describe "what never fades" do
    setup do
      :ok = Crossfade.set_seconds(3)

      :ok
    end

    # **A live stream never ends**, so nothing follows it to fade into.
    test "a live stream" do
      live = Shelf.track("live")
      after_it = Shelf.track("after")
      assert {:ok, _rows} = Playback.replace_queue([live.id, after_it.id])

      play(live)

      refute await_crossfade(20)
    end

    test "the last track of a queue" do
      only = Shelf.track("only")
      assert {:ok, _rows} = Playback.replace_queue([only.id])

      play(only)

      refute await_crossfade(20)
    end

    # A sink of an output that cannot sum two streams answers nothing, and the player
    # then starts no second pipeline at all.
    test "an output whose sink cannot sum two streams" do
      PlayingPipeline.fades(false)
      {first, _second} = two_tracks()

      play(first)

      refute await_crossfade(20)
    end
  end

  # A crossfade is a taste and not an improvement: it takes the silence off the end of a
  # live recording and talks over the first word of a podcast.
  describe "a device that no person changed" do
    test "plays one track at a time" do
      {first, _second} = two_tracks()

      assert Crossfade.seconds() == 0

      play(first)

      refute await_crossfade(20)
    end
  end
end
