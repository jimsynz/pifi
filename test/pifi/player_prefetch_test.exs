defmodule PiFi.PlayerPrefetchTest do
  @moduledoc """
  The audio of the next track arrives before a person asks for it.

  A track that plays from a file waits for the request and for the first 64 KB, and
  both of those waits sit in the gap between one track and the next. Reading the next
  file while the track before it plays removes them.
  """

  use PiFi.DataCase, async: false

  alias PiFi.Cache
  alias PiFi.Playback
  alias PiFi.Player.Download
  alias PiFi.Player.Prefetch

  defmodule Library do
    @moduledoc "A source of tracks that read from a file."

    @behaviour PiFi.Source

    alias PiFi.Playback

    @slug "library"

    @impl PiFi.Source
    def title, do: "Library"

    @impl PiFi.Source
    def icon, do: :library

    @impl PiFi.Source
    def capabilities, do: []

    @impl PiFi.Source
    def roots, do: []

    @impl PiFi.Source
    def kinds, do: [track: "Tracks"]

    @impl PiFi.Source
    def resolve(%{source_ref: "live"}) do
      {:ok,
       %{
         uri: "http://example.test/stream",
         headers: [],
         transport: :http,
         container: :none,
         format: :mp3,
         live?: true,
         position_ms: 0
       }}
    end

    @impl PiFi.Source
    def resolve(item) do
      {:ok,
       %{
         uri: "http://example.test/#{item.source_ref}.mp3",
         headers: [],
         transport: :download,
         container: :none,
         format: :mp3,
         live?: false,
         position_ms: 0,
         key: item.id,
         position_bytes: 0
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
        duration_ms: 600_000,
        keeps_place?: false
      })
    end
  end

  setup do
    Application.put_env(:pifi, Download, plug: {Req.Test, Download}, retry: false)
    Application.put_env(:pifi, :sources, [Library])
    Application.put_env(:pifi, :cache_limit, 10_000)
    Req.Test.set_req_test_from_context(%{async: false})
    Req.Test.stub(Download, fn conn -> Plug.Conn.send_resp(conn, 200, "the audio") end)
    Playback.clear_queue!()

    on_exit(fn ->
      Playback.clear_queue!()
      Application.delete_env(:pifi, Download)
      Application.delete_env(:pifi, :sources)
      Application.delete_env(:pifi, :cache_limit)
      File.rm_rf(Cache.directory())
      File.rm_rf(Download.directory())
    end)

    :ok
  end

  defp held(item) do
    case Cache.fetch(Download.namespace(), item.id) do
      {:ok, entry} -> entry
      {:error, _reason} -> nil
    end
  end

  # The task of `PiFi.Player.Prefetch` reads the file, so a test waits for it rather
  # than for a message of its own. It waits for the release and not for the entry: the
  # entry lands with `keep?` and the task takes that mark off a moment later.
  defp await_released(item, tries \\ 200) do
    case {held(item), tries} do
      {%{keep?: false} = entry, _tries} -> entry
      {_other, 0} -> held(item)
      {_other, _more} -> Process.sleep(10) && await_released(item, tries - 1)
    end
  end

  describe "the queue says which row is next" do
    test "it gives the row after the one that plays, and it moves no mark" do
      first = Library.track("first")
      second = Library.track("second")
      assert {:ok, _rows} = Playback.replace_queue([first.id, second.id])

      assert {:ok, row} = Playback.queue_next_up()
      assert row.item_id == second.id

      # The mark did not move, so the row that plays is still the first one.
      assert {:ok, playing} = Playback.queue_playing()
      assert playing.item_id == first.id
    end

    test "it gives no row at the end of the list" do
      only = Library.track("only")
      assert {:ok, _rows} = Playback.replace_queue([only.id])

      assert {:error, _reason} = Playback.queue_next_up()
    end

    test "it gives no row for a queue that nothing holds" do
      assert {:error, _reason} = Playback.queue_next_up()
    end
  end

  describe "reading one track early" do
    test "the file is on the card, and no mark holds it against an eviction" do
      one = Library.track("one")

      assert Prefetch.ask(one) == :ok

      entry = await_released(one)
      assert entry

      # A person may never reach this track, so the file must not hold the card. See
      # `PiFi.Player.release_file/1` for the fault that this repeats otherwise.
      assert entry.keep? == false
    end

    test "a live stream reads nothing early" do
      live = Library.track("live")

      assert Prefetch.ask(live) == :ignored
      assert held(live) == nil
    end

    test "a track that the card already holds reads nothing again" do
      one = Library.track("one")
      assert Prefetch.ask(one) == :ok
      assert await_released(one)

      Req.Test.stub(Download, fn _conn -> raise "the network must not be read again" end)

      assert Prefetch.ask(one) == :ok
      assert held(one).keep? == false
    end
  end
end
