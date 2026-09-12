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
  alias MyHiFi.Playback
  alias MyHiFi.Player
  alias MyHiFi.Test.PlayingPipeline

  defmodule Episodes do
    @moduledoc """
    A source of three tracks in the catalogue, in one order.

    The player holds items now, so this source writes real ones and resolves them.
    `holds/1` gives the shape of the playable, so one test can take a control away and
    read what the player then answers.
    """

    @behaviour MyHiFi.Source

    alias MyHiFi.Playback

    @slug "episodes"

    @impl MyHiFi.Source
    def title, do: "Episodes"

    # This source is one that the player uses, and no page browses it.
    @impl MyHiFi.Source
    def kinds, do: [track: "Episodes"]

    @impl MyHiFi.Source
    def roots, do: []

    @impl MyHiFi.Source
    def icon, do: :library

    @impl MyHiFi.Source
    def capabilities, do: option(:capabilities, [:skip])

    @impl MyHiFi.Source
    def resolve(item) do
      {:ok,
       %{
         uri: "https://example.test/#{item.source_ref}.mp3",
         headers: [],
         transport: option(:transport, :download),
         container: :none,
         format: option(:format, :mp3),
         live?: option(:live?, false),
         position_ms: 0,
         key: item.source_ref,
         position_bytes: 0
       }}
    end

    @doc "The three episodes of this source, in order, written into the catalogue."
    @spec episodes() :: [MyHiFi.Playback.Item.t()]
    def episodes do
      for number <- 1..3 do
        Playback.upsert_item!(%{
          source: @slug,
          source_ref: "episode-#{number}",
          title: "Episode #{number}",
          kind: :track,
          duration_ms: 600_000,
          # An episode keeps the place that a person stopped at. See
          # `MyHiFi.Playback.Item.Changes.KeepPlaceOnly`.
          keeps_place?: true
        })
      end
    end

    @doc "Change what this source holds, for one test."
    @spec holds(keyword()) :: :ok
    def holds(options) do
      Application.put_env(:my_hi_fi, :episodes_options, options)
    end

    def forget, do: Application.delete_env(:my_hi_fi, :episodes_options)

    defp option(name, default) do
      Application.get_env(:my_hi_fi, :episodes_options, []) |> Keyword.get(name, default)
    end
  end

  setup do
    PlayingPipeline.use_it()
    Application.put_env(:my_hi_fi, :sources, [Episodes])
    Episodes.forget()
    Playback.clear_queue!()
    Event.subscribe(:player)

    on_exit(fn ->
      Player.stop()
      Player.standby(false)
      Episodes.forget()
      Application.delete_env(:my_hi_fi, :sources)

      Playback.clear_queue!()

      for key <- ["last_item", "standby"] do
        case MyHiFi.Settings.fetch(key) do
          {:ok, setting} -> MyHiFi.Settings.delete!(setting)
          {:error, _reason} -> :ok
        end
      end
    end)

    :ok
  end

  # A person presses a track of a list, and the whole list goes in the queue. `number`
  # is the episode that they pressed, counting from 1.
  defp playing(number) do
    episodes = Episodes.episodes()

    assert {:ok, :ok} =
             Playback.play(Enum.map(episodes, & &1.id), %{playing_index: number - 1})

    assert_receive %Events.Started{}, 2000

    Enum.at(episodes, number - 1)
  end

  describe "a pause" do
    test "it stops the audio and it keeps the track" do
      playing(1)

      assert :ok = Player.pause(true)
      assert_receive %Events.Paused{}, 2000

      assert %{paused?: true, playing?: false, item: %{title: "Episode 1"}} = Player.state()
    end

    test "it writes the place, so a play begins there" do
      one = playing(1)

      assert :ok = Player.pause(true)
      assert_receive %Events.Paused{}, 2000

      # `position_bytes` is nil until a write, so a 0 there is what says that the place
      # was written. The time is whatever the test took, which is not always 0 ms.
      assert %{position_bytes: 0} = Playback.get_item!(one.id)
    end

    test "a play starts the track again" do
      playing(1)
      assert :ok = Player.pause(true)
      assert_receive %Events.Paused{}, 2000

      assert :ok = Player.pause(false)
      assert_receive %Events.Started{track: %{title: "Episode 1"}}, 2000

      assert %{paused?: false, playing?: true} = Player.state()
    end

    test "a play of a track that already plays changes nothing" do
      playing(1)

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
      assert %{paused?: false, playing?: false, item: nil} = Player.state()
    end

    test "a pause of a track that plays no more keeps it paused" do
      playing(1)
      assert :ok = Player.pause(true)
      assert_receive %Events.Paused{}, 2000

      assert :ok = Player.pause(true)
      assert %{paused?: true, playing?: false, item: %{title: "Episode 1"}} = Player.state()
    end

    # A stop leaves the device with nothing selected. A pause leaves the track in
    # front of the person, and this is the difference between the two controls.
    test "a stop clears the track and the pause" do
      playing(1)
      assert :ok = Player.pause(true)
      assert_receive %Events.Paused{}, 2000

      assert :ok = Player.stop()

      assert %{paused?: false, item: nil, source: nil} = Player.state()
    end

    test "leaving standby holds a track that a person paused" do
      playing(1)
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
      playing(1)
      assert :ok = Player.standby(true)
      assert_receive %Events.Standby{entered?: true}, 2000

      assert :ok = Player.pause(false)

      assert_receive %Events.Standby{entered?: false}, 2000
      assert_receive %Events.Started{}, 2000
      assert %{standby?: false, playing?: true} = Player.state()
    end

    # A device in standby made sound and stayed in standby, because this path took the
    # state as it found it and every other control woke it. The screen then stayed dark
    # over a track that played, and the automatic standby read a device that plays and
    # never went quiet. The test above covers `pause/1` and not this.
    test "a play of a row leaves standby as well, and not the resume alone" do
      playing(1)
      assert :ok = Player.standby(true)
      assert_receive %Events.Standby{entered?: true}, 2000

      assert :ok = Player.play(Enum.at(Episodes.episodes(), 1))

      assert_receive %Events.Standby{entered?: false}, 2000
      assert_receive %Events.Started{}, 2000
      assert %{standby?: false, playing?: true} = Player.state()
    end

    # A person who asks for music that the device cannot play asked for nothing, so the
    # device stays as quiet as they found it.
    test "a play that cannot happen holds the device in standby" do
      item = playing(1)
      assert :ok = Player.standby(true)
      assert_receive %Events.Standby{entered?: true}, 2000

      assert :ok = Player.enable_source(Episodes, false)
      on_exit(fn -> Player.enable_source(Episodes, true) end)

      assert {:error, :source_not_in_use} = Player.play(item)

      refute_receive %Events.Standby{entered?: false}, 500
      assert %{standby?: true} = Player.state()
    end
  end

  describe "next and previous" do
    test "next plays the track after this one" do
      playing(1)

      assert :ok = Player.next()

      assert_receive %Events.Started{track: %{title: "Episode 2"}}, 2000
    end

    test "previous plays the track before this one" do
      playing(2)

      assert :ok = Player.previous()

      assert_receive %Events.Started{track: %{title: "Episode 1"}}, 2000
    end

    # The place of the track that plays goes to its source first. A person who moves
    # to another track must find this one where they left it.
    test "a move writes the place of the track that played" do
      two = playing(2)

      assert :ok = Player.next()
      assert_receive %Events.Started{track: %{title: "Episode 3"}}, 2000

      assert %{position_bytes: 0} = Playback.get_item!(two.id)
    end

    test "the end of the list gives an error, and the track keeps playing" do
      playing(3)

      assert {:error, :no_more} = Player.next()

      refute_receive %Events.Started{}, 500
      assert %{item: %{title: "Episode 3"}, playing?: true} = Player.state()
    end

    test "the start of the list gives an error" do
      playing(1)

      assert {:error, :no_more} = Player.previous()
    end

    # An empty queue holds no row to move to, and the mark is what a move reads.
    test "a move with an empty queue gives no more" do
      assert {:error, :no_more} = Player.next()
      assert {:error, :no_more} = Player.previous()
    end

    test "a move of a paused track plays it" do
      playing(1)
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
      assert {:ok, :ok} = Playback.play([hd(Episodes.episodes()).id])

      # Two of these: the play, and then the fault that schedules a start.
      assert_receive %Events.Buffering{}, 2000
      assert_receive %Events.Buffering{}, 2000

      PlayingPipeline.fails(false)

      assert {:ok, :ok} =
               Playback.play(Enum.map(Episodes.episodes(), & &1.id), %{playing_index: 1})

      assert_receive %Events.Started{track: %{title: "Episode 2"}}, 2000

      # The stale start would build a second pipeline beside the one that plays, and
      # it would say that it began.
      refute_receive %Events.Started{}, 3000
      assert %{item: %{title: "Episode 2"}, playing?: true} = Player.state()
    end

    # A timer that has already fired cannot be cancelled, so the message reaches the
    # player whatever it does. On the board this left a pipeline that held `aplay` and
    # kept the room loud: the notices of that pipeline reached a player that no longer
    # knew it, the page held the buffering state for ever, and a stop stopped nothing.
    test "a start that arrives after the person moved on builds no second pipeline" do
      playing(1)
      pipeline = :sys.get_state(Player).pipeline

      send(Player, :restart)
      Process.sleep(200)

      assert :sys.get_state(Player).pipeline == pipeline
      assert Process.alive?(pipeline)
      refute_receive %Events.Started{}, 500
    end

    test "a start that arrives while the player is paused makes no sound" do
      playing(1)
      assert :ok = Player.pause(true)
      assert_receive %Events.Paused{}, 2000

      send(Player, :restart)
      Process.sleep(200)

      assert %{paused?: true, playing?: false} = Player.state()
      refute_receive %Events.Started{}, 500
    end
  end

  describe "a skip" do
    test "it moves the count that a person reads" do
      playing(1)

      assert :ok = Player.skip(30_000)

      # The player publishes a progress event each second as well, so the guard is
      # what tells the one that the skip caused from a tick that came before it.
      assert_receive %Events.Progress{position_ms: position} when position >= 30_000, 2000
    end

    test "a backward skip moves the count back" do
      playing(1)
      assert :ok = Player.skip(60_000)
      assert_receive %Events.Progress{position_ms: forward} when forward >= 60_000, 2000

      assert :ok = Player.skip(-15_000)

      # A tick of one second that came before the first skip still holds a count near
      # zero, so the guard names the band that the second skip lands in.
      assert_receive %Events.Progress{position_ms: back} when back >= 40_000 and back < 60_000,
                     2000

      assert back < forward
    end

    # The source measures the audio that it stepped over, and the player follows that
    # number. Nothing here turns a byte into a time.
    test "the count follows the source, and not the request" do
      playing(1)
      PlayingPipeline.moves(12_345)

      assert :ok = Player.skip(30_000)

      # A tick of one second carries a count near zero, so the guard names the band
      # that the source measured and the tick cannot reach.
      assert_receive %Events.Progress{position_ms: position}
                     when position >= 12_345 and position < 30_000,
                     2000
    end

    test "a live stream holds no skip" do
      Episodes.holds(live?: true)
      playing(1)

      assert {:error, :cannot_skip} = Player.skip(30_000)
    end

    test "a source that holds no skip gives an error" do
      Episodes.holds(capabilities: [:next, :previous])
      playing(1)

      assert {:error, :cannot_skip} = Player.skip(30_000)
    end

    # `MyHiFi.Player.AdtsFrame` reads AAC, so a track of that codec moves in the same
    # way that an episode of MP3 does.
    test "a track of AAC takes a skip" do
      Episodes.holds(format: :aac)
      playing(1)

      assert :ok = Player.skip(30_000)
    end

    # `MyHiFi.Player.FlacFrame` bisects the file, because a FLAC header names the
    # sample that its frame begins at and never the length of the frame.
    test "a track of FLAC takes a skip" do
      Episodes.holds(format: :flac)
      playing(1)

      assert :ok = Player.skip(30_000)
    end

    # **`flac` reads one stream from its own beginning**, so the reader cannot move
    # under it. A skip of such a codec builds the pipeline again, and the buffering
    # state is what a person sees while it does. See
    # `MyHiFi.Player.Pipeline.decoder_holds_stream?/1`.
    test "a skip of FLAC builds the pipeline again" do
      Episodes.holds(format: :flac)
      playing(1)

      assert :ok = Player.skip(30_000)

      assert_receive %Events.Buffering{}, 2000
      assert_receive %Events.Started{}, 2000
      assert %{playing?: true} = Player.state()
    end

    # MP3 keeps the pipeline, because `Membrane.MP3.MAD.Decoder` finds the next frame
    # by itself. A restart would cost a person the silence of a start for nothing.
    test "a skip of MP3 keeps the pipeline" do
      playing(1)

      # The play published one of these before the sound began, and `playing/1` waits
      # for the sound and leaves it. A second one would be the pipeline of a restart.
      assert_received %Events.Buffering{}

      assert :ok = Player.skip(30_000)

      refute_receive %Events.Buffering{}, 500
    end

    # `MyHiFi.Player.Skip.frames/1` names the codecs that this firmware reads the
    # frames of, and Ogg Vorbis is not one of them.
    test "a format that holds no frame reader gives an error" do
      Episodes.holds(format: :vorbis)
      playing(1)

      assert {:error, :cannot_skip} = Player.skip(30_000)
    end

    # A live stream has no file to move inside, and `MyHiFi.Player.FileSource` is the
    # element that moves.
    test "a transport that reads no file gives an error" do
      Episodes.holds(transport: :http)
      playing(1)

      assert {:error, :cannot_skip} = Player.skip(30_000)
    end

    test "a track that makes no sound holds no skip" do
      playing(1)
      assert :ok = Player.pause(true)
      assert_receive %Events.Paused{}, 2000

      assert {:error, :not_playing} = Player.skip(30_000)
    end

    test "nothing selected holds no skip" do
      assert {:error, :not_playing} = Player.skip(30_000)
    end
  end
end
