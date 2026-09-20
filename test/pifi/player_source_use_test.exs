defmodule PiFi.PlayerSourceUseTest do
  @moduledoc """
  What the player does when a person takes a source out of use.

  A source out of use leaves each user interface, and its background jobs do
  nothing. The player holds two more parts of the same answer: it stops the sound
  of that source, and it does not select the source again after a restart.
  """

  use PiFi.DataCase, async: false

  alias PiFi.Event
  alias PiFi.Event.Player, as: Events
  alias PiFi.Playback
  alias PiFi.Player
  alias PiFi.Settings
  alias PiFi.Source
  alias PiFi.Test.PlayingPipeline
  alias PiFi.Test.SilentOutput

  defmodule Station do
    @moduledoc "One live track in the catalogue, and nothing else."

    @behaviour PiFi.Source

    alias PiFi.Playback

    @slug "station"

    @impl PiFi.Source
    def title, do: "A station"

    # This source is one that the player uses, and no page browses it.
    @impl PiFi.Source
    def kinds, do: [track: "Stations"]

    @impl PiFi.Source
    def roots, do: []

    @impl PiFi.Source
    def icon, do: :radio

    @impl PiFi.Source
    def capabilities, do: []

    @impl PiFi.Source
    def resolve(_item) do
      {:ok,
       %{
         uri: "https://example.test/stream.mp3",
         headers: [],
         transport: :http,
         container: :none,
         format: :mp3,
         live?: true,
         position_ms: 0,
         key: nil,
         position_bytes: nil
       }}
    end

    @doc "The one station of this source, in the catalogue."
    @spec item() :: PiFi.Playback.Item.t()
    def item do
      Playback.upsert_item!(%{
        source: @slug,
        source_ref: "one",
        title: "A station",
        kind: :track,
        live?: true
      })
    end
  end

  setup do
    PlayingPipeline.use_it()
    SilentOutput.use_it()
    Application.put_env(:pifi, :sources, [Station])
    Event.subscribe(:player)

    on_exit(fn ->
      Player.stop()
      Application.delete_env(:pifi, :sources)

      for key <- [Source.enabled_key(Station)] do
        case Settings.fetch(key) do
          {:ok, setting} -> Settings.delete!(setting)
          {:error, _reason} -> :ok
        end
      end
    end)

    :ok
  end

  defp playing do
    assert {:ok, :ok} = Playback.play([Station.item().id])
    assert_receive %Events.Started{}, 2000
    :ok
  end

  describe "a source that goes out of use" do
    test "the sound of it stops" do
      playing()

      assert :ok = Player.enable_source(Station, false)

      assert_receive %Events.Stopped{reason: :requested}, 2000
      assert %{playing?: false, source: nil} = Player.state()
    end

    test "another source keeps playing" do
      playing()

      assert :ok = Player.enable_source(PiFi.Test.PlainSource, false)

      refute_receive %Events.Stopped{}, 200
      assert %{playing?: true} = Player.state()
    end

    test "the player refuses to play it" do
      assert :ok = Player.enable_source(Station, false)

      assert {:error, _reason} = Playback.play([Station.item().id])
    end

    # The queue lives through a restart, so the row of a source that a person put away
    # is still there. Turning the source on again brings it back, and until then the
    # device selects nothing. See `PiFi.Playback.Queue`.
    test "a queue that points at it selects nothing" do
      playing()
      assert :ok = Player.stop()
      assert [_row] = Playback.queue!()

      Source.enable(Station, false)
      restart_player()

      assert %{source: nil, item: nil} = Player.state()
    end

    test "a queue that points at a source in use comes back" do
      playing()
      assert :ok = Player.stop()

      restart_player()

      assert %{source: Station, paused?: true} = Player.state()
    end
  end

  # The player reads the settings when it starts, so a test of a restart must start
  # it again. The supervisor puts it back.
  defp restart_player do
    pid = Process.whereis(Player)
    reference = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^reference, :process, ^pid, :killed}, 2000

    wait_for_player()
  end

  defp wait_for_player(tries \\ 50) do
    case Process.whereis(Player) do
      nil when tries > 0 ->
        Process.sleep(20)
        wait_for_player(tries - 1)

      pid when is_pid(pid) ->
        # The state comes from a `handle_continue`, so a read waits for it.
        Player.state()
        :ok
    end
  end
end
