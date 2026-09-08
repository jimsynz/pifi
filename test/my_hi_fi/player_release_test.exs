defmodule MyHiFi.PlayerReleaseTest do
  @moduledoc """
  What the player does to the file of a track that a person stops.

  The `:mark_played` action of `MyHiFi.Playback.Item` covers a track that reaches its
  end by itself. A person who stops half way through a song reaches that path never, so
  the file of that song held `keep?` for ever and no eviction could take it. Each such
  track made the card smaller. `keeps_place?` of the item is what separates the two.
  """

  use MyHiFi.DataCase, async: false

  alias MyHiFi.Cache
  alias MyHiFi.Event
  alias MyHiFi.Event.Player, as: Events
  alias MyHiFi.Playback
  alias MyHiFi.Player
  alias MyHiFi.Player.Download
  alias MyHiFi.Test.PlayingPipeline

  defmodule Library do
    @moduledoc """
    A source of two tracks: one that keeps its place, and one that does not.

    An episode of a podcast and a chapter of an audiobook keep their place. A song
    does not, and one library holds both.
    """

    @behaviour MyHiFi.Source

    alias MyHiFi.Playback

    @slug "library"

    @impl MyHiFi.Source
    def title, do: "Library"

    @impl MyHiFi.Source
    def icon, do: :library

    @impl MyHiFi.Source
    def capabilities, do: []

    @impl MyHiFi.Source
    def roots, do: []

    @impl MyHiFi.Source
    def kinds, do: [track: "Tracks"]

    @impl MyHiFi.Source
    def resolve(_item) do
      {:ok,
       %{
         uri: "http://example.test/track.mp3",
         headers: [],
         transport: :download,
         container: :none,
         format: :mp3,
         live?: false,
         position_ms: 0,
         key: "unused",
         position_bytes: 0
       }}
    end

    @doc "A track that a person goes back to, on a later day."
    @spec episode() :: MyHiFi.Playback.Item.t()
    def episode, do: track("episode", true)

    @doc "A track that a person does not go back to."
    @spec song() :: MyHiFi.Playback.Item.t()
    def song, do: track("song", false)

    defp track(ref, keeps_place?) do
      Playback.upsert_item!(%{
        source: @slug,
        source_ref: ref,
        title: "The #{ref}",
        kind: :track,
        duration_ms: 600_000,
        keeps_place?: keeps_place?
      })
    end
  end

  setup do
    PlayingPipeline.use_it()
    Playback.clear_queue!()
    Application.put_env(:my_hi_fi, :sources, [Library])
    Application.put_env(:my_hi_fi, :cache_limit, 10_000)
    Event.subscribe(:player)

    on_exit(fn ->
      Player.stop()
      Playback.clear_queue!()
      Application.delete_env(:my_hi_fi, :sources)
      Application.delete_env(:my_hi_fi, :cache_limit)
      File.rm_rf(Cache.directory())
    end)

    :ok
  end

  # What `MyHiFi.Player.Download` leaves behind: a whole file that no eviction may
  # take while a person is in the middle of it.
  defp kept_file(item) do
    Cache.put!(Download.namespace(), item.id, %{
      bytes: "the audio",
      content_type: "audio/mpeg",
      keep?: true,
      weight: 1
    })
  end

  defp kept?(item) do
    {:ok, entry} = Cache.fetch(Download.namespace(), item.id)

    entry.keep?
  end

  defp play(item) do
    assert {:ok, :ok} = Playback.play([item.id])
    assert_receive %Events.Started{}, 2000

    item
  end

  describe "a person stops a track" do
    test "a track that keeps no place gives up its file" do
      song = Library.song() |> tap(&kept_file/1) |> play()

      Player.stop()

      refute kept?(song)
    end

    test "a track that keeps its place holds its file for the day that a person goes on" do
      episode = Library.episode() |> tap(&kept_file/1) |> play()

      Player.stop()

      assert kept?(episode)
    end
  end

  describe "a person plays another track" do
    test "the track that a person left gives up its file, when it keeps no place" do
      song = Library.song() |> tap(&kept_file/1) |> play()
      episode = Library.episode()

      play(episode)

      refute kept?(song)
    end

    test "the track that a person left holds its file, when it keeps its place" do
      episode = Library.episode() |> tap(&kept_file/1) |> play()
      song = Library.song()

      play(song)

      assert kept?(episode)
    end
  end
end
