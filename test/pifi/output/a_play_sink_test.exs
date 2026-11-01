defmodule PiFi.Output.APlaySinkTest do
  @moduledoc """
  The sink that writes the samples.

  **`PiFi.Output.APlayPort` is one process for the whole node**, and the silence of a
  stop reaches the program through it, so this file cannot run beside another that holds
  that port.
  """

  use ExUnit.Case, async: false

  alias PiFi.Output.APlayPort
  alias PiFi.Output.APlaySink
  alias PiFi.Output.APlaySink.State

  @format %Membrane.RawAudio{sample_format: :s24le, sample_rate: 44_100, channels: 2}

  # The files that `cat` writes go in one directory with a random name, for the reasons
  # that `PiFi.Output.APlayPortTest` gives.
  setup_all do
    scratch =
      Path.join(
        System.tmp_dir!(),
        "a_play_sink_test_#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    File.mkdir_p!(scratch)
    on_exit(fn -> File.rm_rf!(scratch) end)

    %{scratch: scratch}
  end

  setup do
    on_exit(fn -> APlayPort.close() end)

    :ok
  end

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

  # **The sink asks for one buffer at a time**, and only once the one before it is
  # written. That is what holds the pipeline to the speed of the card.
  describe "the demand" do
    test "it asks for the first buffer when the pipeline plays" do
      assert {[demand: {:input, 1}], _state} = APlaySink.handle_playing(nil, %State{})
    end

    test "it asks for the next buffer when the last one is written", %{scratch: scratch} do
      {state, _path} = writing(scratch)

      assert {[], state} = APlaySink.handle_buffer(:input, frames(2), nil, state)
      assert state.request

      assert {[demand: {:input, 1}], state} = answered(state)
      assert state.request == nil
    end
  end

  describe "the notice that sound started" do
    test "the first buffer says so, and the next ones say nothing", %{scratch: scratch} do
      # The sink is the only part that knows that samples arrived. A source cannot
      # say it: a stream that never arrives, a playlist with no segment, and a
      # decoder that gives nothing all look the same from up there.
      {state, _path} = writing(scratch)
      state = %State{state | sounded?: false}

      {[], state} = APlaySink.handle_buffer(:input, frames(1), nil, state)
      assert {[notify_parent: :playing, demand: {:input, 1}], state} = answered(state)
      assert state.sounded?

      {[], state} = APlaySink.handle_buffer(:input, frames(1), nil, state)
      assert {[demand: {:input, 1}], _state} = answered(state)
    end
  end

  # **A track that leaves a part of a frame in the port turns every sample after it
  # into noise.** `aplay` reads frames of a fixed width and it holds no marker to find
  # the start of one, so a stream that is one byte short shifts every sample that
  # follows. The next track sounds as noise as well, because the program is the same
  # one. See the moduledoc.
  describe "the frames that reach the port" do
    test "a buffer of whole frames goes as it is", %{scratch: scratch} do
      {state, path} = writing(scratch)
      buffer = %Membrane.Buffer{payload: <<1::size(12 * 8)>>}

      assert {[], state} = APlaySink.handle_buffer(:input, buffer, nil, state)
      {_actions, state} = answered(state)

      assert state.part == <<>>
      assert eventually(fn -> byte_size(read(path)) == 12 end)
    end

    # A frame of this stream is 6 bytes: 3 for each of the two channels.
    test "a buffer that ends inside a frame keeps the rest for the next one",
         %{scratch: scratch} do
      {state, path} = writing(scratch)

      {[], state} = APlaySink.handle_buffer(:input, bytes(<<1::size(8 * 8)>>), nil, state)
      {_actions, state} = answered(state)

      assert byte_size(state.part) == 2
      assert eventually(fn -> byte_size(read(path)) == 6 end)

      {[], state} = APlaySink.handle_buffer(:input, bytes(<<2::size(4 * 8)>>), nil, state)
      {_actions, state} = answered(state)

      assert state.part == <<>>
      assert eventually(fn -> byte_size(read(path)) == 12 end)
    end

    # **This is the fault of #59.** A person pressed next in the middle of a track,
    # the decoder was cut mid-frame, and every sample of the next track came a byte
    # late for as long as the program ran.
    test "the end of a track pads the part of a frame, so the count stays whole",
         %{scratch: scratch} do
      {state, path} = writing(scratch)

      {[], state} = APlaySink.handle_buffer(:input, bytes(<<1::size(8 * 8)>>), nil, state)
      {_actions, state} = answered(state)

      assert {[], ended} = APlaySink.handle_end_of_stream(:input, nil, state)

      assert ended.part == <<>>
      assert eventually(fn -> byte_size(read(path)) == 12 end)
    end

    # **`PiFi.Player` stops the pipeline as soon as the end arrives**, which can be
    # before the last buffer is written, so the end hands over the padded part without
    # waiting, and the holder keeps it behind the buffer still in flight.
    test "the end of a track doesn't wait for the buffer in flight", %{scratch: scratch} do
      {state, path} = writing(scratch)
      payload = :binary.copy(<<1, 2, 3, 4, 5, 6>>, 4) <> <<7, 8>>

      {[], state} = APlaySink.handle_buffer(:input, bytes(payload), nil, state)
      assert state.request

      assert {[], _ended} = APlaySink.handle_end_of_stream(:input, nil, state)

      assert eventually(fn -> read(path) == payload <> <<0, 0, 0, 0>> end)
    end

    test "the end of a track that lands on a frame pads nothing", %{scratch: scratch} do
      {state, path} = writing(scratch)

      assert {[], ended} = APlaySink.handle_end_of_stream(:input, nil, state)

      assert ended.part == <<>>
      Process.sleep(100)
      assert read(path) == <<>>
    end

    # A person who stopped hears nothing more, and the next track starts a program of
    # its own in any case.
    test "a stop drops the part of a frame" do
      {:ok, port} = APlayPort.hold("cat", [])
      state = %State{device: "null", port: port, format: @format, part: <<1, 2>>}

      assert {[], state} = APlaySink.handle_parent_notification(:silence, nil, state)

      assert state.part == <<>>
    end

    # A buffer of less than one frame makes no sound, so it says that none started, and
    # it asks for the next buffer at once because there's nothing to wait for.
    test "a buffer that holds no whole frame says that nothing sounded", %{scratch: scratch} do
      {state, _path} = writing(scratch)
      state = %State{state | sounded?: false}

      assert {[demand: {:input, 1}], state} =
               APlaySink.handle_buffer(:input, bytes(<<1, 2, 3>>), nil, state)

      refute state.sounded?
      assert state.request == nil
      assert byte_size(state.part) == 3
    end
  end

  describe "the silence that a stop asks for" do
    test "it ends the program, so the room is quiet at once" do
      # The holder owns the port, so the silence reaches the program through it.
      {:ok, port} = APlayPort.hold("cat", [])
      state = %State{device: "null", port: port, sounded?: true}

      assert {[], state} = APlaySink.handle_parent_notification(:silence, nil, state)

      assert state.port == nil
      assert state.silent?
      refute Port.info(port)
      assert APlayPort.held() == nil
    end

    # **This is the stop that waited behind the samples.** The sink used to write to the
    # port itself, so it sat suspended while the card caught up and read `:silence` only
    # after every buffer queued in front of it had played. `sleep` reads nothing, so the
    # second buffer here would have held the sink for good.
    test "a buffer that the card holds up doesn't hold up the stop" do
      {:ok, port} = APlayPort.hold("sh", ["-c", "exec sleep 30"])
      state = %State{device: "null", port: port, format: @format, sounded?: true}
      samples = bytes(:binary.copy(<<0>>, 512 * 1024))

      {[], state} = APlaySink.handle_buffer(:input, samples, nil, state)
      {[demand: {:input, 1}], state} = answered(state)

      {microseconds, {[], state}} =
        :timer.tc(fn -> APlaySink.handle_buffer(:input, samples, nil, state) end)

      assert microseconds < 100_000

      {microseconds, {actions, state}} =
        :timer.tc(fn -> APlaySink.handle_parent_notification(:silence, nil, state) end)

      assert microseconds < 500_000
      assert APlayPort.held() == nil

      # A port that still holds bytes for a program that's been killed closes once the
      # write to it fails, a moment later. The kill is what makes the room quiet.
      assert eventually(fn -> Port.info(port) == nil end)

      # The buffer that was in flight is dropped, so the null sink asks for the next one,
      # and the pipeline stops in its own time instead of stalling.
      assert actions == [demand: {:input, 1}]
      assert state.request == nil
    end

    test "a buffer after that goes nowhere, and it raises nothing" do
      state = %State{device: "null", port: nil, silent?: true}
      buffer = %Membrane.Buffer{payload: "samples that no person hears"}

      assert {[demand: {:input, 1}], ^state} = APlaySink.handle_buffer(:input, buffer, nil, state)
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

    # **A change of rate inside one stream opens a new program**, and the old one takes
    # the buffer in flight with it. Its answer is `:closed`, and reading that as the end
    # of the pipeline would stop the track at the change.
    test "a new format forgets the buffer in flight and asks for the next one",
         %{scratch: scratch} do
      # The program takes the arguments of `aplay`, and like the card it reads nothing,
      # so the second buffer is still in flight when the format changes.
      program = Path.join(scratch, "fake-aplay")
      File.write!(program, "#!/bin/sh\nexec sleep 30\n")
      File.chmod!(program, 0o755)
      Application.put_env(:pifi, :aplay_command, program)
      on_exit(fn -> Application.delete_env(:pifi, :aplay_command) end)

      samples = bytes(:binary.copy(<<0>>, 512 * 1024))
      state = %State{device: "null", sounded?: true}

      {[], state} = APlaySink.handle_stream_format(:input, @format, nil, state)
      {[], state} = APlaySink.handle_buffer(:input, samples, nil, state)
      {[demand: {:input, 1}], state} = answered(state)
      {[], state} = APlaySink.handle_buffer(:input, samples, nil, state)
      assert state.request

      other = %Membrane.RawAudio{@format | sample_rate: 48_000}

      assert {[demand: {:input, 1}], state} =
               APlaySink.handle_stream_format(:input, other, nil, state)

      assert state.request == nil
      assert is_port(state.port)

      assert_receive message
      assert {[], ^state} = APlaySink.handle_info(message, nil, state)
    end
  end

  describe "the end of a track" do
    # **The program plays on.** ALSA holds about half a second, and the holder keeps the
    # card open, so that half second sounds and the next pipeline writes to the same
    # port. Ending the program here cut the last half second of every track.
    test "it ends no program, so the last half second sounds" do
      {:ok, port} = APlayPort.hold("cat", [])
      state = %State{device: "null", port: port, sounded?: true}

      assert {[], state} = APlaySink.handle_end_of_stream(:input, nil, state)

      assert state.port == nil
      assert Port.info(port)
      assert APlayPort.held() == {"cat", []}
    end

    # **The silence between one track and the next is the number that #159 is about.**
    # The sink of the track that ends and the sink of the track that follows are two
    # elements of two pipelines, so the holder of the port is what measures it.
    test "the end of a track and the first samples of the next are both noted" do
      handler = "sink-gap-#{:erlang.unique_integer([:positive])}"
      probe = self()

      :telemetry.attach(
        handler,
        [:pifi, :player, :gap],
        fn _event, measurements, _metadata, _config -> send(probe, {:gap, measurements}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, port} = APlayPort.hold("cat", [])

      {[], _ended} =
        APlaySink.handle_end_of_stream(:input, nil, %State{
          device: "null",
          port: port,
          sounded?: true
        })

      next = %State{device: "null", port: port, format: @format, sounded?: false}
      {[], next} = APlaySink.handle_buffer(:input, frames(1), nil, next)

      assert {[notify_parent: :playing, demand: {:input, 1}], _state} = answered(next)

      assert_receive {:gap, %{duration: duration}}
      assert duration >= 0
    end

    # A person who stopped already got their silence, so a pipeline that goes ends
    # nothing either.
    test "a pipeline that stops ends no program" do
      {:ok, port} = APlayPort.hold("cat", [])
      state = %State{device: "null", port: port}

      assert {[terminate: :normal], state} = APlaySink.handle_terminate_request(nil, state)

      assert state.port == nil
      assert Port.info(port)
    end
  end

  describe "a program that is gone" do
    # The holder reads the exit of the program and holds the reason. This element ends
    # the pipeline, and `PiFi.Player` starts the stream again.
    test "a write to a port that went ends the pipeline" do
      {:ok, port} = APlayPort.hold("cat", [])
      :ok = APlayPort.close()
      state = %State{device: "null", port: port, sounded?: true}
      buffer = %Membrane.Buffer{payload: "samples for a program that is gone"}

      {[], state} = APlaySink.handle_buffer(:input, buffer, nil, state)

      assert {[terminate: :normal], state} = answered(state)
      assert state.port == nil
    end
  end

  describe "handle_info" do
    test "another message changes nothing" do
      state = %State{device: "null"}

      assert {[], ^state} = APlaySink.handle_info(:something_else, nil, state)
    end

    test "another message changes nothing while a buffer is in flight", %{scratch: scratch} do
      {state, _path} = writing(scratch)
      {[], state} = APlaySink.handle_buffer(:input, frames(1), nil, state)

      assert {[], ^state} = APlaySink.handle_info(:something_else, nil, state)
    end
  end

  # A sink that writes to `cat`, which puts every byte in a file of its own.
  defp writing(scratch) do
    path = Path.join(scratch, "sink_#{System.unique_integer([:positive])}")
    {:ok, port} = APlayPort.hold("sh", ["-c", "cat -u > #{path}"])

    {%State{device: "null", port: port, format: @format, sounded?: true}, path}
  end

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> bytes
      {:error, _reason} -> <<>>
    end
  end

  defp frames(count), do: bytes(<<0::size(count * 6)-unit(8)>>)

  defp bytes(payload), do: %Membrane.Buffer{payload: payload}

  # The answer to the buffer in flight, handed to the sink as Membrane would hand it.
  defp answered(%State{} = state) do
    assert_receive message, 2_000
    APlaySink.handle_info(message, nil, state)
  end

  defp eventually(check, attempts \\ 500)

  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(20)
      eventually(check, attempts - 1)
    end
  end
end
