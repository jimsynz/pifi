defmodule PiFi.Player.CaptureSourceTest do
  use ExUnit.Case, async: true

  doctest PiFi.Player.CaptureSource

  alias Membrane.Buffer
  alias Membrane.RawAudio
  alias PiFi.Player.CaptureSource
  alias PiFi.Player.CaptureSource.State
  alias PiFi.Spotify.Loopback

  describe "what it is told to capture" do
    test "it reads the capture half of the loopback unless a caller says otherwise" do
      assert {[], %State{device: device}} =
               CaptureSource.handle_init(nil, options(device: nil))

      assert device == Loopback.capture_device()
    end

    test "a caller may name another device" do
      assert {[], %State{device: "hw:Test,0,0"}} =
               CaptureSource.handle_init(nil, options(device: "hw:Test,0,0"))
    end

    # **The format is a fact and not a discovery**, because `arecord` is told it on the
    # command line. `PiFi.Player.PortDecoder` has to read a WAV header; this does not.
    test "the arguments and the format agree" do
      assert ["-D", _d, "-f", "S16_LE", "-r", "44100", "-c", "2", "-t", "raw"] =
               CaptureSource.argv("hw:Loopback,1,0")
    end

    # A2DP is negotiated with the telephone, so the rate is the caller's. Naming 44100
    # for a sender that agreed 48000 plays the audio 8.8% slow.
    test "a caller may name the rate and the channel count that the far end agreed to" do
      assert {[], %State{sample_rate: 48_000, channels: 1}} =
               CaptureSource.handle_init(
                 nil,
                 options(
                   device: "bluealsa:DEV=AA:BB:CC:DD:EE:FF,PROFILE=a2dp",
                   sample_rate: 48_000,
                   channels: 1
                 )
               )
    end
  end

  # **The format it declares and the format it asks for must agree**, or the pipeline
  # is told one thing and given another. `true` stands in for `arecord`: it takes the
  # arguments, exits, and the actions are what this is reading.
  test "the format it declares is the format the arguments ask for" do
    state = %State{device: "hw:Loopback,1,0", command: "true", sample_rate: 44_100, channels: 2}

    assert {[stream_format: {:output, format}], _state} = CaptureSource.handle_playing(nil, state)

    assert %RawAudio{channels: 2, sample_rate: 44_100, sample_format: :s16le} = format

    argv = CaptureSource.argv(state.device)
    assert "S16_LE" in argv
    assert to_string(format.sample_rate) in argv
    assert to_string(format.channels) in argv
  end

  describe "what it does with what arrives" do
    setup do
      %{
        state: %State{
          device: "hw:Loopback,1,0",
          command: "arecord",
          sample_rate: 44_100,
          channels: 2,
          port: :fake_port
        }
      }
    end

    test "bytes from the port become one buffer", %{state: state} do
      assert {[buffer: {:output, %Buffer{payload: "abc"}}], ^state} =
               CaptureSource.handle_info({:fake_port, {:data, "abc"}}, nil, state)
    end

    # A cast that ended takes `arecord` with it, and a pipeline that raised there would
    # report an error for something a person did on purpose.
    test "the program leaving ends the stream rather than failing", %{state: state} do
      assert {[end_of_stream: :output], %State{port: nil}} =
               CaptureSource.handle_info({:fake_port, {:exit_status, 0}}, nil, state)
    end

    test "a non-zero status still ends the stream", %{state: state} do
      assert {[end_of_stream: :output], %State{port: nil}} =
               CaptureSource.handle_info({:fake_port, {:exit_status, 1}}, nil, state)
    end

    test "a message from something else is ignored", %{state: state} do
      assert {[], ^state} = CaptureSource.handle_info(:something_else, nil, state)
    end

    # A port of another element must not end this one's stream.
    test "data from another port is ignored", %{state: state} do
      assert {[], ^state} = CaptureSource.handle_info({:other_port, {:data, "x"}}, nil, state)
    end
  end

  defp options(overrides) do
    %{device: nil, command: "arecord", sample_rate: 44_100, channels: 2}
    |> Map.merge(Map.new(overrides))
  end
end
