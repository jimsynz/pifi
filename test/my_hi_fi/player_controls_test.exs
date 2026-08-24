defmodule MyHiFi.PlayerControlsTest do
  @moduledoc """
  The controls of the player: pause, next, previous, and skip.

  `MyHiFi.Source.InternetRadio` and `MyHiFi.Source.Podcasts` hold their own tests of
  the order that next and previous move through. This one holds what the player does
  with the answer, so it uses a source of three tracks and a pipeline that makes no
  sound.
  """

  use MyHiFi.DataCase, async: false

  alias MyHiFi.Event
  alias MyHiFi.Event.Player, as: Events
  alias MyHiFi.Player
  alias MyHiFi.Test.PlayingPipeline

  defmodule Episodes do
    @moduledoc """
    A source of three tracks, in one order, with no wrap at either end.

    `holds/1` gives the list of capabilities, and the shape of the playable, so one
    test can take a control away and read what the player then answers.
    """

    @behaviour MyHiFi.Source

    @refs [{:episode, 1}, {:episode, 2}, {:episode, 3}]

    @impl MyHiFi.Source
    def title, do: "Episodes"

    @impl MyHiFi.Source
    def icon, do: :library

    @impl MyHiFi.Source
    def capabilities, do: option(:capabilities, [:next, :previous, :skip])

    @impl MyHiFi.Source
    def root, do: :root

    @impl MyHiFi.Source
    def browse(:root, _options) do
      {:ok, %{entries: Enum.map(@refs, &{:track, entry(&1)}), cursor: nil}}
    end

    @impl MyHiFi.Source
    def search(_query, _options), do: {:error, :not_supported}

    @impl MyHiFi.Source
    def track({:episode, _number} = ref), do: {:ok, entry(ref)}

    def track(ref), do: {:error, {:not_a_track, ref}}

    @impl MyHiFi.Source
    def resolve({:episode, number}) do
      {:ok,
       %{
         uri: "https://example.test/#{number}.mp3",
         headers: [],
         transport: option(:transport, :download),
         container: :none,
         format: option(:format, :mp3),
         live?: option(:live?, false),
         position_ms: 0,
         key: "episode-#{number}",
         position_bytes: 0
       }}
    end

    def resolve(ref), do: {:error, {:not_a_track, ref}}

    @impl MyHiFi.Source
    def next(ref), do: beside(ref, 1)

    @impl MyHiFi.Source
    def previous(ref), do: beside(ref, -1)

    @impl MyHiFi.Source
    def favourite(_ref, _true?), do: {:error, :not_supported}

    @impl MyHiFi.Source
    def store_position(ref, place) do
      record({:store_position, ref, place})
    end

    @impl MyHiFi.Source
    def finished(ref), do: record({:finished, ref})

    @impl MyHiFi.Source
    def ref_to_string({:episode, number}), do: {:ok, "episode:#{number}"}

    @impl MyHiFi.Source
    def ref_from_string("episode:" <> number), do: {:ok, {:episode, String.to_integer(number)}}

    def ref_from_string(_name), do: {:error, :not_a_name}

    @doc "Change what this source holds, for one test."
    @spec holds(keyword()) :: :ok
    def holds(options) do
      Application.put_env(:my_hi_fi, :episodes_options, options)
    end

    @doc "Everything that the player has said, oldest first."
    def calls, do: Enum.reverse(Application.get_env(:my_hi_fi, :episodes_calls, []))

    def forget do
      Application.delete_env(:my_hi_fi, :episodes_calls)
      Application.delete_env(:my_hi_fi, :episodes_options)
    end

    defp beside(ref, step) do
      case Enum.find_index(@refs, &(&1 == ref)) do
        nil -> {:error, :no_more}
        index -> at(index + step)
      end
    end

    defp at(place) when place < 0, do: {:error, :no_more}

    defp at(place) do
      case Enum.at(@refs, place) do
        nil -> {:error, :no_more}
        ref -> {:ok, ref}
      end
    end

    defp option(name, default) do
      Application.get_env(:my_hi_fi, :episodes_options, []) |> Keyword.get(name, default)
    end

    defp entry({:episode, number}) do
      %{
        ref: {:episode, number},
        title: "Episode #{number}",
        subtitle: nil,
        artwork: nil,
        duration_ms: 600_000,
        favourite?: nil
      }
    end

    defp record(call) do
      calls = Application.get_env(:my_hi_fi, :episodes_calls, [])
      Application.put_env(:my_hi_fi, :episodes_calls, [call | calls])
      :ok
    end
  end

  setup do
    PlayingPipeline.use_it()
    Application.put_env(:my_hi_fi, :sources, [Episodes])
    Episodes.forget()
    Event.subscribe(:player)

    on_exit(fn ->
      Player.stop()
      Player.standby(false)
      Episodes.forget()
      Application.delete_env(:my_hi_fi, :sources)

      for key <- ["last_source", "last_ref", "standby"] do
        case MyHiFi.Settings.fetch(key) do
          {:ok, setting} -> MyHiFi.Settings.delete!(setting)
          {:error, _reason} -> :ok
        end
      end
    end)

    :ok
  end

  defp playing(ref) do
    assert :ok = Player.play(Episodes, ref)
    assert_receive %Events.Started{}, 2000
    :ok
  end

  describe "a pause" do
    test "it stops the audio and it keeps the track" do
      playing({:episode, 1})

      assert :ok = Player.pause(true)
      assert_receive %Events.Paused{}, 2000

      assert %{paused?: true, playing?: false, track: %{title: "Episode 1"}} = Player.state()
    end

    test "it writes the place, so a play begins there" do
      playing({:episode, 1})

      assert :ok = Player.pause(true)
      assert_receive %Events.Paused{}, 2000

      assert Enum.any?(Episodes.calls(), &match?({:store_position, {:episode, 1}, _place}, &1))
    end

    test "a play starts the track again" do
      playing({:episode, 1})
      assert :ok = Player.pause(true)
      assert_receive %Events.Paused{}, 2000

      assert :ok = Player.pause(false)
      assert_receive %Events.Started{track: %{title: "Episode 1"}}, 2000

      assert %{paused?: false, playing?: true} = Player.state()
    end

    test "a play of a track that already plays changes nothing" do
      playing({:episode, 1})

      assert :ok = Player.pause(false)

      refute_receive %Events.Started{}, 500
      assert %{paused?: false, playing?: true} = Player.state()
    end

    test "a play with nothing selected gives an error" do
      assert {:error, :nothing_selected} = Player.pause(false)
    end

    # A pause holds a track for a person, and a device with nothing selected holds
    # none.
    test "a pause with nothing selected changes nothing" do
      assert :ok = Player.pause(true)
      assert %{paused?: false, playing?: false, track: nil} = Player.state()
    end

    test "a pause of a track that plays no more keeps it paused" do
      playing({:episode, 1})
      assert :ok = Player.pause(true)
      assert_receive %Events.Paused{}, 2000

      assert :ok = Player.pause(true)
      assert %{paused?: true, playing?: false, track: %{title: "Episode 1"}} = Player.state()
    end

    # A stop leaves the device with nothing selected. A pause leaves the track in
    # front of the person, and this is the difference between the two controls.
    test "a stop clears the track and the pause" do
      playing({:episode, 1})
      assert :ok = Player.pause(true)
      assert_receive %Events.Paused{}, 2000

      assert :ok = Player.stop()

      assert %{paused?: false, track: nil, source: nil} = Player.state()
    end

    test "leaving standby holds a track that a person paused" do
      playing({:episode, 1})
      assert :ok = Player.pause(true)
      assert_receive %Events.Paused{}, 2000
      assert :ok = Player.standby(true)
      assert_receive %Events.Standby{entered?: true}, 2000

      assert :ok = Player.standby(false)
      assert_receive %Events.Standby{entered?: false}, 2000

      # A person who paused a track and then pressed standby did not ask for music.
      refute_receive %Events.Started{}, 500
      assert %{paused?: true, playing?: false} = Player.state()
    end

    test "a play leaves standby, because a person asked for music" do
      playing({:episode, 1})
      assert :ok = Player.standby(true)
      assert_receive %Events.Standby{entered?: true}, 2000

      assert :ok = Player.pause(false)

      assert_receive %Events.Standby{entered?: false}, 2000
      assert_receive %Events.Started{}, 2000
      assert %{standby?: false, playing?: true} = Player.state()
    end
  end

  describe "next and previous" do
    test "next plays the track after this one" do
      playing({:episode, 1})

      assert :ok = Player.next()

      assert_receive %Events.Started{track: %{title: "Episode 2"}}, 2000
    end

    test "previous plays the track before this one" do
      playing({:episode, 2})

      assert :ok = Player.previous()

      assert_receive %Events.Started{track: %{title: "Episode 1"}}, 2000
    end

    # The place of the track that plays goes to its source first. A person who moves
    # to another track must find this one where they left it.
    test "a move writes the place of the track that played" do
      playing({:episode, 2})

      assert :ok = Player.next()
      assert_receive %Events.Started{track: %{title: "Episode 3"}}, 2000

      assert Enum.any?(Episodes.calls(), &match?({:store_position, {:episode, 2}, _place}, &1))
    end

    test "the end of the list gives an error, and the track keeps playing" do
      playing({:episode, 3})

      assert {:error, :no_more} = Player.next()

      refute_receive %Events.Started{}, 500
      assert %{track: %{title: "Episode 3"}, playing?: true} = Player.state()
    end

    test "the start of the list gives an error" do
      playing({:episode, 1})

      assert {:error, :no_more} = Player.previous()
    end

    test "a source that holds no order gives an error" do
      playing({:episode, 1})
      Episodes.holds(capabilities: [:skip])

      assert {:error, :not_supported} = Player.next()
      assert {:error, :not_supported} = Player.previous()
    end

    test "a move with nothing selected gives an error" do
      assert {:error, :nothing_selected} = Player.next()
      assert {:error, :nothing_selected} = Player.previous()
    end

    test "a move of a paused track plays it" do
      playing({:episode, 1})
      assert :ok = Player.pause(true)
      assert_receive %Events.Paused{}, 2000

      assert :ok = Player.next()

      assert_receive %Events.Started{track: %{title: "Episode 2"}}, 2000
      assert %{paused?: false, playing?: true} = Player.state()
    end
  end

  # A stream that fails schedules a start, and a person who chooses something else
  # inside those two seconds must not meet that start. Two pipelines mean two `aplay`
  # programs, and the second one finds the sound card busy.
  describe "a stream that failed, and a person who moves on" do
    test "a play cancels the start that the fault scheduled" do
      PlayingPipeline.fails(true)
      assert :ok = Player.play(Episodes, {:episode, 1})

      # Two of these: the play, and then the fault that schedules a start.
      assert_receive %Events.Buffering{}, 2000
      assert_receive %Events.Buffering{}, 2000

      PlayingPipeline.fails(false)
      assert :ok = Player.play(Episodes, {:episode, 2})
      assert_receive %Events.Started{track: %{title: "Episode 2"}}, 2000

      # The stale start would build a second pipeline beside the one that plays, and
      # it would say that it began.
      refute_receive %Events.Started{}, 3000
      assert %{track: %{title: "Episode 2"}, playing?: true} = Player.state()
    end
  end

  describe "a skip" do
    test "it moves the count that a person reads" do
      playing({:episode, 1})

      assert :ok = Player.skip(30_000)

      assert_receive %Events.Progress{position_ms: position}, 2000
      assert position >= 30_000
    end

    test "a backward skip moves the count back" do
      playing({:episode, 1})
      assert :ok = Player.skip(60_000)
      assert_receive %Events.Progress{position_ms: forward}, 2000

      assert :ok = Player.skip(-15_000)

      assert_receive %Events.Progress{position_ms: back}, 2000
      assert back < forward
    end

    # The source measures the audio that it stepped over, and the player follows that
    # number. Nothing here turns a byte into a time.
    test "the count follows the source, and not the request" do
      playing({:episode, 1})
      PlayingPipeline.moves(12_345)

      assert :ok = Player.skip(30_000)

      assert_receive %Events.Progress{position_ms: position}, 2000
      assert position < 30_000
      assert position >= 12_345
    end

    test "a live stream holds no skip" do
      Episodes.holds(live?: true)
      playing({:episode, 1})

      assert {:error, :cannot_skip} = Player.skip(30_000)
    end

    test "a source that holds no skip gives an error" do
      Episodes.holds(capabilities: [:next, :previous])
      playing({:episode, 1})

      assert {:error, :cannot_skip} = Player.skip(30_000)
    end

    # `MyHiFi.Player.Skip` reads MP3 frames, and an ADTS frame needs another parser.
    test "a format that holds no frame reader gives an error" do
      Episodes.holds(format: :aac)
      playing({:episode, 1})

      assert {:error, :cannot_skip} = Player.skip(30_000)
    end

    # A live stream has no file to move inside, and `MyHiFi.Player.FileSource` is the
    # element that moves.
    test "a transport that reads no file gives an error" do
      Episodes.holds(transport: :http)
      playing({:episode, 1})

      assert {:error, :cannot_skip} = Player.skip(30_000)
    end

    test "a track that makes no sound holds no skip" do
      playing({:episode, 1})
      assert :ok = Player.pause(true)
      assert_receive %Events.Paused{}, 2000

      assert {:error, :not_playing} = Player.skip(30_000)
    end

    test "nothing selected holds no skip" do
      assert {:error, :not_playing} = Player.skip(30_000)
    end
  end
end
