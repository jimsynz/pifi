defmodule MyHiFi.Output.APlaySinkTest do
  @moduledoc """
  The sink that writes the samples.

  **`MyHiFi.Output.APlayPort` is one process for the whole node**, and the silence of a
  stop reaches the program through it, so this file cannot run beside another that holds
  that port.
  """

  use ExUnit.Case, async: false

  alias MyHiFi.Output.APlayPort
  alias MyHiFi.Output.APlaySink
  alias MyHiFi.Output.APlaySink.State

  describe "alsa_format/1" do
    test "packs a 24-bit sample in three bytes" do
      # Membrane holds a 24-bit sample in 3 bytes, and `S24_LE` in ALSA holds it in
      # 4. libmad gives 24-bit samples for each MP3 stream, so the wrong name here
      # gives noise and not music.
      assert APlaySink.alsa_format(:s24le) == "S24_3LE"
      assert APlaySink.alsa_format(:s24be) == "S24_3BE"
      assert APlaySink.alsa_format(:u24le) == "U24_3LE"
      assert APlaySink.alsa_format(:u24be) == "U24_3BE"
    end

    test "names each format that a decoder of this firmware gives" do
      # libmad gives `:s24le`, and fdk-aac gives `:s16le`.
      assert APlaySink.alsa_format(:s16le) == "S16_LE"
      assert APlaySink.alsa_format(:s24le) == "S24_3LE"
    end

    test "names each other format of Membrane" do
      for {format, name} <- [
            s8: "S8",
            u8: "U8",
            s16le: "S16_LE",
            s16be: "S16_BE",
            u16le: "U16_LE",
            u16be: "U16_BE",
            s32le: "S32_LE",
            s32be: "S32_BE",
            u32le: "U32_LE",
            u32be: "U32_BE",
            f32le: "FLOAT_LE",
            f32be: "FLOAT_BE",
            f64le: "FLOAT64_LE",
            f64be: "FLOAT64_BE"
          ] do
        assert APlaySink.alsa_format(format) == name
      end
    end
  end

  describe "handle_init" do
    test "holds the device of the output" do
      assert {[], state} = APlaySink.handle_init(nil, %{device: "plughw:CARD=Audio,DEV=0"})
      assert state.device == "plughw:CARD=Audio,DEV=0"
      assert state.port == nil
      refute state.sounded?
    end
  end

  describe "the notice that sound started" do
    test "the first buffer says so, and the next ones say nothing" do
      # The sink is the only part that knows that samples arrived. A source cannot
      # say it: a stream that never arrives, a playlist with no segment, and a
      # decoder that gives nothing all look the same from up there.
      port = Port.open({:spawn, "cat"}, [:binary])
      state = %State{device: "null", port: port, sounded?: false}
      buffer = %Membrane.Buffer{payload: "some samples"}

      assert {[notify_parent: :playing], state} =
               APlaySink.handle_buffer(:input, buffer, nil, state)

      assert state.sounded?

      assert {[], _state} = APlaySink.handle_buffer(:input, buffer, nil, state)

      Port.close(port)
    end
  end

  # **A track that leaves a part of a frame in the port turns every sample after it
  # into noise.** `aplay` reads frames of a fixed width and it holds no marker to find
  # the start of one, so a stream that is one byte short shifts every sample that
  # follows. The next track sounds as noise as well, because the program is the same
  # one. See the moduledoc.
  describe "the frames that reach the port" do
    @format %Membrane.RawAudio{sample_format: :s24le, sample_rate: 44_100, channels: 2}

    defp reader do
      port = Port.open({:spawn, "cat"}, [:binary])
      on_exit(fn -> if Port.info(port), do: Port.close(port) end)

      port
    end

    defp written(port, count) do
      receive do
        {^port, {:data, bytes}} when byte_size(bytes) >= count -> bytes
        {^port, {:data, bytes}} -> bytes <> written(port, count - byte_size(bytes))
      after
        2000 -> <<>>
      end
    end

    test "a buffer of whole frames goes as it is" do
      port = reader()
      state = %State{device: "null", port: port, format: @format, sounded?: true}
      buffer = %Membrane.Buffer{payload: <<1::size(12 * 8)>>}

      assert {[], state} = APlaySink.handle_buffer(:input, buffer, nil, state)

      assert state.part == <<>>
      assert byte_size(written(port, 12)) == 12
    end

    # A frame of this stream is 6 bytes: 3 for each of the two channels.
    test "a buffer that ends inside a frame keeps the rest for the next one" do
      port = reader()
      state = %State{device: "null", port: port, format: @format, sounded?: true}

      assert {[], state} =
               APlaySink.handle_buffer(
                 :input,
                 %Membrane.Buffer{payload: <<1::size(8 * 8)>>},
                 nil,
                 state
               )

      assert byte_size(state.part) == 2
      assert byte_size(written(port, 6)) == 6

      assert {[], state} =
               APlaySink.handle_buffer(
                 :input,
                 %Membrane.Buffer{payload: <<2::size(4 * 8)>>},
                 nil,
                 state
               )

      assert state.part == <<>>
      assert byte_size(written(port, 6)) == 6
    end

    # **This is the fault of #59.** A person pressed next in the middle of a track,
    # the decoder was cut mid-frame, and every sample of the next track came a byte
    # late for as long as the program ran.
    test "the end of a track pads the part of a frame, so the count stays whole" do
      port = reader()
      state = %State{device: "null", port: port, format: @format, sounded?: true}

      assert {[], state} =
               APlaySink.handle_buffer(
                 :input,
                 %Membrane.Buffer{payload: <<1::size(8 * 8)>>},
                 nil,
                 state
               )

      assert byte_size(written(port, 6)) == 6

      assert {[], state} = APlaySink.handle_end_of_stream(:input, nil, state)

      assert state.part == <<>>
      assert byte_size(written(port, 6)) == 6
    end

    test "the end of a track that lands on a frame pads nothing" do
      port = reader()
      state = %State{device: "null", port: port, format: @format, sounded?: true, part: <<>>}

      assert {[], state} = APlaySink.handle_end_of_stream(:input, nil, state)

      assert state.part == <<>>
      assert written(port, 1) == <<>>
    end

    # A person who stopped hears nothing more, and the next track starts a program of
    # its own in any case.
    test "a stop drops the part of a frame" do
      {:ok, port} = APlayPort.hold("cat", [])
      on_exit(fn -> APlayPort.close() end)
      state = %State{device: "null", port: port, format: @format, part: <<1, 2>>}

      assert {[], state} = APlaySink.handle_parent_notification(:silence, nil, state)

      assert state.part == <<>>
    end

    # A buffer of less than one frame makes no sound, so it says that none started.
    test "a buffer that holds no whole frame says that nothing sounded" do
      port = reader()
      state = %State{device: "null", port: port, format: @format, sounded?: false}
      buffer = %Membrane.Buffer{payload: <<1, 2, 3>>}

      assert {[], state} = APlaySink.handle_buffer(:input, buffer, nil, state)

      refute state.sounded?
      assert byte_size(state.part) == 3
    end
  end

  describe "the silence that a stop asks for" do
    test "it ends the program, so the room is quiet at once" do
      # The holder owns the port, so the silence reaches the program through it.
      {:ok, port} = APlayPort.hold("cat", [])
      on_exit(fn -> APlayPort.close() end)
      state = %State{device: "null", port: port, sounded?: true}

      assert {[], state} = APlaySink.handle_parent_notification(:silence, nil, state)

      assert state.port == nil
      assert state.silent?
      refute Port.info(port)
      assert APlayPort.held() == nil
    end

    test "a buffer after that goes nowhere, and it raises nothing" do
      state = %State{device: "null", port: nil, silent?: true}
      buffer = %Membrane.Buffer{payload: "samples that no person hears"}

      assert {[], ^state} = APlaySink.handle_buffer(:input, buffer, nil, state)
    end

    test "a new format starts no program, so nothing sounds again" do
      format = %Membrane.RawAudio{sample_format: :s24le, sample_rate: 44_100, channels: 2}
      state = %State{device: "null", port: nil, silent?: true}

      assert {[], state} = APlaySink.handle_stream_format(:input, format, nil, state)

      assert state.port == nil
    end

    test "any other notice from the parent changes nothing" do
      state = %State{device: "null"}

      assert {[], ^state} = APlaySink.handle_parent_notification(:something, nil, state)
    end
  end

  describe "handle_stream_format" do
    test "the same format again starts no second program" do
      format = %Membrane.RawAudio{sample_format: :s24le, sample_rate: 44_100, channels: 2}
      state = %State{device: "null", format: format}

      assert {[], ^state} = APlaySink.handle_stream_format(:input, format, nil, state)
    end
  end

  describe "the end of a track" do
    # **The program plays on.** ALSA holds about half a second, and the holder keeps the
    # card open, so that half second sounds and the next pipeline writes to the same
    # port. Ending the program here cut the last half second of every track.
    test "it ends no program, so the last half second sounds" do
      {:ok, port} = APlayPort.hold("cat", [])
      on_exit(fn -> APlayPort.close() end)
      state = %State{device: "null", port: port, sounded?: true}

      assert {[], state} = APlaySink.handle_end_of_stream(:input, nil, state)

      assert state.port == nil
      assert Port.info(port)
      assert APlayPort.held() == {"cat", []}
    end

    # A person who stopped already got their silence, so a pipeline that goes ends
    # nothing either.
    test "a pipeline that stops ends no program" do
      {:ok, port} = APlayPort.hold("cat", [])
      on_exit(fn -> APlayPort.close() end)
      state = %State{device: "null", port: port}

      assert {[terminate: :normal], state} = APlaySink.handle_terminate_request(nil, state)

      assert state.port == nil
      assert Port.info(port)
    end
  end

  describe "a program that is gone" do
    # The holder reads the exit of the program and holds the reason. This element ends
    # the pipeline, and `MyHiFi.Player` starts the stream again.
    test "a write to a port that went ends the pipeline" do
      port = Port.open({:spawn, "cat"}, [:binary])
      Port.close(port)
      state = %State{device: "null", port: port, sounded?: true}
      buffer = %Membrane.Buffer{payload: "samples for a program that is gone"}

      assert {[terminate: :normal], state} = APlaySink.handle_buffer(:input, buffer, nil, state)

      assert state.port == nil
    end
  end

  describe "handle_info" do
    test "another message changes nothing" do
      state = %State{device: "null"}

      assert {[], ^state} = APlaySink.handle_info(:something_else, nil, state)
    end
  end
end
