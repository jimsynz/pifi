defmodule MyHiFi.Output.APlaySinkTest do
  use ExUnit.Case, async: true

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

  describe "the silence that a stop asks for" do
    test "it closes the program, so the room is quiet at once" do
      port = Port.open({:spawn, "cat"}, [:binary])
      state = %State{device: "null", port: port, sounded?: true}

      assert {[], state} = APlaySink.handle_parent_notification(:silence, nil, state)

      assert state.port == nil
      assert state.silent?
      refute Port.info(port)
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

  describe "handle_info" do
    test "a program that stopped ends the pipeline" do
      port = Port.open({:spawn, "cat"}, [:binary])
      state = %State{device: "null", port: port}

      assert {[terminate: :normal], state} =
               APlaySink.handle_info({port, {:exit_status, 1}}, nil, state)

      assert state.port == nil

      Port.close(port)
    end

    test "another message changes nothing" do
      state = %State{device: "null"}

      assert {[], ^state} = APlaySink.handle_info(:something_else, nil, state)
    end
  end
end
