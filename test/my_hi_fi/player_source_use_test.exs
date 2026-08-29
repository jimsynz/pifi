defmodule MyHiFi.PlayerSourceUseTest do
  @moduledoc """
  What the player does when a person takes a source out of use.

  A source out of use leaves each user interface, and its background jobs do
  nothing. The player holds two more parts of the same answer: it stops the sound
  of that source, and it does not select the source again after a restart.
  """

  use MyHiFi.DataCase, async: false

  alias MyHiFi.Event
  alias MyHiFi.Event.Player, as: Events
  alias MyHiFi.Playback
  alias MyHiFi.Player
  alias MyHiFi.Settings
  alias MyHiFi.Source
  alias MyHiFi.Test.PlayingPipeline

  defmodule Station do
    @moduledoc "One live track in the catalogue, and nothing else."

    @behaviour MyHiFi.Source

    alias MyHiFi.Playback

    @slug "station"

    @impl MyHiFi.Source
    def title, do: "A station"

    # This source is one that the player uses, and no page browses it.
    @impl MyHiFi.Source
    def kinds, do: [track: "Stations"]

    @impl MyHiFi.Source
    def roots, do: []

    @impl MyHiFi.Source
    def icon, do: :radio

    @impl MyHiFi.Source
    def capabilities, do: []

    @impl MyHiFi.Source
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
    @spec item() :: MyHiFi.Playback.Item.t()
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
    Application.put_env(:my_hi_fi, :sources, [Station])
    Event.subscribe(:player)

    on_exit(fn ->
      Player.stop()
      Application.delete_env(:my_hi_fi, :sources)

      for key <- ["last_item", Source.enabled_key(Station)] do
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

      assert :ok = Player.enable_source(MyHiFi.Test.PlainSource, false)

      refute_receive %Events.Stopped{}, 200
      assert %{playing?: true} = Player.state()
    end

    test "the player refuses to play it" do
      assert :ok = Player.enable_source(Station, false)

      assert {:error, _reason} = Playback.play([Station.item().id])
    end

    test "a restart does not select it again" do
      playing()
      assert :ok = Player.enable_source(Station, false)

      # The name of the last track goes with it, so nothing points at a source that
      # a person put away.
      assert {:error, _reason} = Settings.fetch("last_item")
    end

    test "a name in the settings that points at it selects nothing" do
      playing()
      assert :ok = Player.stop()
      assert {:ok, %{value: _id}} = Settings.fetch("last_item")

      Source.enable(Station, false)
      restart_player()

      assert %{source: nil, item: nil} = Player.state()
    end

    test "a name in the settings that points at a source in use comes back" do
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
