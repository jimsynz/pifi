defmodule MyHiFi.Player.PipelineTest do
  use ExUnit.Case, async: true

  alias MyHiFi.Player.Pipeline

  # `handle_init/2` builds the whole spec, and it raises for a combination that
  # holds no branch. A host cannot play, because it holds no USB DAC, so this is
  # the step that a test can reach.
  defp init(overrides) do
    playable =
      Map.merge(
        %{
          uri: "http://radio.test/stream",
          headers: [],
          transport: :http,
          container: :none,
          format: :mp3,
          live?: true
        },
        overrides
      )

    Pipeline.handle_init(nil, %{
      playable: playable,
      buffer_bytes: 64 * 1024,
      sink: %MyHiFi.Output.APlaySink{device: "null"},
      parent: self()
    })
  end

  # A track of a library is a file that `MyHiFi.Player.Download` wrote, so it names a
  # key and a place to begin at. See `MyHiFi.Player.FileSource`.
  defp downloaded(overrides) do
    Map.merge(
      %{transport: :download, live?: false, key: "an-item", position_bytes: 0},
      overrides
    )
  end

  describe "the combinations that a New Zealand station gives" do
    test "a plain HTTP stream of MP3" do
      assert {[spec: _spec], %{parent: _pid}} = init(%{transport: :http, format: :mp3})
    end

    test "a plain HTTP stream of AAC" do
      assert {[spec: _spec], _state} = init(%{transport: :http, format: :aac})
    end

    test "HLS with AAC and no container, which 14 stations give" do
      assert {[spec: _spec], _state} =
               init(%{transport: :hls, container: :none, format: :aac})
    end

    test "HLS with AAC inside MPEG-TS" do
      assert {[spec: _spec], _state} =
               init(%{transport: :hls, container: :mpeg_ts, format: :aac})
    end

    test "HLS with MP3 inside MPEG-TS, which 8 stations give" do
      assert {[spec: _spec], _state} =
               init(%{transport: :hls, container: :mpeg_ts, format: :mp3})
    end
  end

  # **A sample of 550 tracks of one real Plex library on 2026-09-14 gave 311 FLAC, 161
  # MP3 and 78 AAC in MP4.** The first two read as they are, and the third is one that
  # the server converts, so it arrives as `:hls, :mpeg_ts, :mp3` above.
  describe "the containers that a music library of a household gives" do
    test "AAC in ADTS with no container" do
      assert {[spec: _spec], _state} = init(downloaded(%{container: :none, format: :aac}))
    end

    test "FLAC as the server holds it" do
      assert {[spec: _spec], _state} = init(downloaded(%{container: :none, format: :flac}))
    end
  end

  describe "the codecs that a program decodes" do
    test "Ogg Vorbis, which 3 stations give" do
      assert {[spec: _spec], _state} = init(%{container: :ogg, format: :vorbis})
    end

    test "Ogg FLAC, which 3 stations give" do
      assert {[spec: _spec], _state} = init(%{container: :ogg, format: :flac})
    end

    test "FLAC with no container" do
      assert {[spec: _spec], _state} = init(%{container: :none, format: :flac})
    end
  end

  describe "a codec that needs a program this firmware holds none of" do
    test "Opus inside Ogg raises and says so" do
      assert_raise ArgumentError, ~r/No pipeline for :opus in :ogg/, fn ->
        init(%{container: :ogg, format: :opus})
      end
    end
  end

  describe "a combination with no branch" do
    test "an unknown codec raises" do
      assert_raise ArgumentError, ~r/No pipeline for :unknown/, fn ->
        init(%{format: :unknown})
      end
    end
  end

  describe "the parent" do
    test "holds the process that started the pipeline" do
      assert {_actions, %{parent: parent}} = init(%{})
      assert parent == self()
    end
  end
end
