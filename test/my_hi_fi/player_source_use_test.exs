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
  alias MyHiFi.Player
  alias MyHiFi.Settings
  alias MyHiFi.Source
  alias MyHiFi.Test.PlayingPipeline

  defmodule Station do
    @moduledoc "One live track, and nothing else."

    @behaviour MyHiFi.Source

    @ref {:station, 1}

    @impl MyHiFi.Source
    def title, do: "A station"

    @impl MyHiFi.Source
    def icon, do: :radio

    @impl MyHiFi.Source
    def capabilities, do: []

    @impl MyHiFi.Source
    def root, do: :root

    @impl MyHiFi.Source
    def browse(:root, _options), do: {:ok, %{entries: [{:track, entry()}], cursor: nil}}

    @impl MyHiFi.Source
    def search(_query, _options), do: {:error, :not_supported}

    @impl MyHiFi.Source
    def track(@ref), do: {:ok, entry()}

    def track(ref), do: {:error, {:not_a_track, ref}}

    @impl MyHiFi.Source
    def resolve(@ref) do
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

    def resolve(ref), do: {:error, {:not_a_track, ref}}

    @impl MyHiFi.Source
    def next(_ref), do: {:error, :not_supported}

    @impl MyHiFi.Source
    def previous(_ref), do: {:error, :not_supported}

    @impl MyHiFi.Source
    def ref_to_string(@ref), do: {:ok, "station:1"}

    def ref_to_string(_ref), do: {:error, :cannot_name}

    @impl MyHiFi.Source
    def ref_from_string("station:1"), do: {:ok, @ref}

    def ref_from_string(_name), do: {:error, :not_a_name}

    @impl MyHiFi.Source
    def favourite(_ref, _true?), do: {:error, :not_supported}

    @impl MyHiFi.Source
    def store_position(_ref, _place), do: :ok

    @impl MyHiFi.Source
    def finished(_ref), do: :ok

    @doc "The one track of this source."
    def ref, do: @ref

    defp entry do
      %{
        ref: @ref,
        title: "A station",
        subtitle: nil,
        artwork: nil,
        duration_ms: nil,
        favourite?: nil
      }
    end
  end

  setup do
    PlayingPipeline.use_it()
    Application.put_env(:my_hi_fi, :sources, [Station])
    Event.subscribe(:player)

    on_exit(fn ->
      Player.stop()
      Application.delete_env(:my_hi_fi, :sources)

      for key <- ["last_source", "last_ref", Source.enabled_key(Station)] do
        case Settings.fetch(key) do
          {:ok, setting} -> Settings.delete!(setting)
          {:error, _reason} -> :ok
        end
      end
    end)

    :ok
  end

  defp playing do
    assert :ok = Player.play(Station, Station.ref())
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

      assert {:error, :source_not_in_use} = Player.play(Station, Station.ref())
    end

    test "a restart does not select it again" do
      playing()
      assert :ok = Player.enable_source(Station, false)

      # The name of the last track goes with it, so nothing points at a source that
      # a person put away.
      assert {:error, _reason} = Settings.fetch("last_source")
      assert {:error, _reason} = Settings.fetch("last_ref")
    end

    test "a name in the settings that points at it selects nothing" do
      playing()
      assert :ok = Player.stop()
      assert {:ok, %{value: _name}} = Settings.fetch("last_source")

      Source.enable(Station, false)
      restart_player()

      assert %{source: nil, track: nil} = Player.state()
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
