defmodule PiFi.Player.PortDecoderTest do
  use ExUnit.Case, async: true

  alias PiFi.Player.PortDecoder
  alias PiFi.Player.PortDecoder.State

  # Captured from `oggdec --quiet -o - -` on 2026-08-22. The length of the data is
  # `0x7FFFFFD3`, because a live stream has no length.
  @oggdec_header <<0x52, 0x49, 0x46, 0x46, 0xF7, 0xFF, 0xFF, 0x7F, 0x57, 0x41, 0x56, 0x45, 0x66,
                   0x6D, 0x74, 0x20, 0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x02, 0x00, 0x44, 0xAC,
                   0x00, 0x00, 0x10, 0xB1, 0x02, 0x00, 0x04, 0x00, 0x10, 0x00, 0x64, 0x61, 0x74,
                   0x61, 0xD3, 0xFF, 0xFF, 0x7F>>

  # Captured from `flac --decode --ogg --stdout --silent -` on the same day. This
  # one writes 0 for the length, and it warns about that.
  @flac_header <<0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45, 0x66,
                 0x6D, 0x74, 0x20, 0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x02, 0x00, 0x44, 0xAC,
                 0x00, 0x00, 0x10, 0xB1, 0x02, 0x00, 0x04, 0x00, 0x10, 0x00, 0x64, 0x61, 0x74,
                 0x61, 0x00, 0x00, 0x00, 0x00>>

  defp state, do: %State{command: "oggdec", arguments: ["-"], port: nil}

  defp feed(chunks) do
    Enum.reduce(chunks, {[], state()}, fn chunk, {actions, state} ->
      {more, state} = PortDecoder.handle_info({nil, {:data, chunk}}, nil, state)
      {actions ++ more, state}
    end)
  end

  defp format(actions) do
    Enum.find_value(actions, fn
      {:stream_format, {:output, format}} -> format
      _other -> nil
    end)
  end

  defp demand(state, count), do: PortDecoder.handle_demand(:output, count, :buffers, nil, state)

  defp buffer_sizes(actions) do
    for {:buffer, {:output, buffers}} <- actions, buffer <- buffers, do: byte_size(buffer.payload)
  end

  defp audio(actions) do
    for {:buffer, {:output, buffers}} <- actions,
        buffer <- buffers,
        into: <<>>,
        do: buffer.payload
  end

  describe "the end of the input" do
    # **This is the bug that left a track playing silence past its end.** The element
    # closed its port and sent nothing, so the sink kept the card open and
    # `PiFi.Player.Pipeline` never told the player to play the next track. A device
    # held a FLAC track of 3:44 at 5:32 and counted on.
    test "reaches the output, so the pipeline can end" do
      {_actions, state} = feed([@flac_header <> "the samples"])

      assert {[], state} = PortDecoder.handle_end_of_stream(:input, nil, %{state | port: :fake})
      assert state.ending?

      assert {[redemand: :output], state} =
               PortDecoder.handle_info({:fake, {:exit_status, 0}}, nil, state)

      assert state.port == nil

      assert {actions, state} = demand(state, 8)
      assert audio(actions) == "the samples"
      assert List.last(actions) == {:end_of_stream, :output}
      assert state.held == <<>>
    end

    # **The programs keep the tail of the audio until their input closes**, so what
    # they write after the end of the input is part of the track. The stream ends
    # when the program exits, and not before.
    test "an answer after the input ended is kept, and the stream waits for the exit" do
      {_actions, state} = feed([@flac_header <> "the samples"])

      assert {[], state} = PortDecoder.handle_end_of_stream(:input, nil, %{state | port: :fake})

      assert {actions, state} =
               PortDecoder.handle_info({:fake, {:data, " and the tail"}}, nil, state)

      refute {:end_of_stream, :output} in actions
      assert state.held == "the samples and the tail"

      {_actions, state} = PortDecoder.handle_info({:fake, {:exit_status, 0}}, nil, state)
      assert {actions, _state} = demand(state, 8)
      assert audio(actions) == "the samples and the tail"
      assert List.last(actions) == {:end_of_stream, :output}
    end

    # An element that holds no port has nothing to wait for, apart from the sink.
    test "a port that is already closed sends what it holds, and then ends the stream" do
      {_actions, state} = feed([@flac_header <> "the samples"])

      assert {[redemand: :output], state} = PortDecoder.handle_end_of_stream(:input, nil, state)

      assert {actions, _state} = demand(state, 1)
      assert List.last(actions) == {:end_of_stream, :output}
    end

    test "a port that is already closed and holds nothing ends the stream at once" do
      {_actions, state} = feed([@flac_header])

      assert {[end_of_stream: :output], _state} =
               PortDecoder.handle_end_of_stream(:input, nil, state)
    end

    test "the end of the stream goes out once" do
      {_actions, state} = feed([@flac_header])
      {[end_of_stream: :output], state} = PortDecoder.handle_end_of_stream(:input, nil, state)

      assert {[], _state} = PortDecoder.handle_info({nil, {:exit_status, 1}}, nil, state)
    end
  end

  # **The sink counts its queue in buffers, and it can't read `:silence` while it waits
  # on `aplay`.** This element used to send each answer of the program as it arrived,
  # whatever the sink asked for, and an answer of `flac` is about 100 ms. A measurement
  # on the host found 1.9 s of FLAC and 27.6 s of Vorbis in front of a stop.
  describe "demand" do
    # One second of 44100 Hz stereo `s16le`, and 25 ms of it.
    @second :binary.copy(<<0>>, 176_400)
    @buffer_bytes 4412

    defp running(chunks) do
      {_actions, state} = feed(chunks)
      %{state | port: :fake}
    end

    test "nothing leaves until the sink asks" do
      {actions, state} = feed([@flac_header <> @second])

      assert audio(actions) == ""
      assert byte_size(state.held) == 176_400
    end

    test "the sink gets as many buffers as it asks for, each 25 ms long" do
      state = running([@flac_header <> @second])

      assert {actions, state} = demand(state, 3)
      assert buffer_sizes(actions) == [@buffer_bytes, @buffer_bytes, @buffer_bytes]
      assert byte_size(state.held) == 176_400 - 3 * @buffer_bytes
    end

    test "a piece shorter than a buffer waits while the program runs" do
      state = running([@flac_header <> "the samples"])

      assert {actions, %{held: "the samples"}} = demand(state, 5)
      assert audio(actions) == ""
    end

    test "the program gets more input only while the decoder holds little" do
      state = running([@flac_header <> @second])

      assert {actions, state} = demand(state, 1)
      refute Keyword.has_key?(actions, :demand)

      assert {actions, _state} = demand(state, 36)
      assert {:demand, {:input, 4096}} in actions
    end

    test "the input asks for nothing after it ends" do
      state = %{running([@flac_header]) | ending?: true}

      assert {actions, _state} = demand(state, 1)
      refute Keyword.has_key?(actions, :demand)
    end
  end

  describe "the header that each program writes" do
    test "reads the one from oggdec" do
      {actions, state} = feed([@oggdec_header <> "the samples"])

      assert format(actions) == %Membrane.RawAudio{
               channels: 2,
               sample_rate: 44_100,
               sample_format: :s16le
             }

      assert state.held == "the samples"
    end

    test "reads the one from flac, which names a length of zero" do
      {actions, state} = feed([@flac_header <> "the samples"])

      assert format(actions).sample_rate == 44_100
      assert state.held == "the samples"
    end

    test "names the format once, and not for each buffer" do
      {actions, state} = feed([@oggdec_header <> "first", "second", "third"])

      assert Enum.count(actions, &match?({:stream_format, _}, &1)) == 1
      assert state.held == "firstsecondthird"
    end
  end

  describe "a header that arrives in pieces" do
    test "one byte at a time still gives the format and the audio" do
      whole = @oggdec_header <> "the samples"
      chunks = whole |> :binary.bin_to_list() |> Enum.map(&<<&1>>)

      {actions, state} = feed(chunks)

      assert format(actions).sample_rate == 44_100
      assert state.held == "the samples"
    end

    test "a chunk that ends inside the RIFF marker" do
      whole = @oggdec_header <> "the samples"
      <<first::binary-size(2), rest::binary>> = whole

      {actions, state} = feed([first, rest])

      assert format(actions).channels == 2
      assert state.held == "the samples"
    end

    test "a chunk that ends inside the fmt chunk" do
      whole = @oggdec_header <> "the samples"
      <<first::binary-size(24), rest::binary>> = whole

      {actions, state} = feed([first, rest])

      assert format(actions).sample_rate == 44_100
      assert state.held == "the samples"
    end

    test "nothing leaves before the header is whole" do
      {actions, state} = feed([binary_part(@oggdec_header, 0, 30)])

      assert format(actions) == nil
      assert audio(actions) == ""
      assert byte_size(state.held) == 30
      assert state.format == nil
    end
  end

  describe "a header with more chunks in it" do
    test "steps over a chunk that it does not need" do
      # A WAV file may hold a `LIST` chunk before the audio.
      extra = "LIST" <> <<8::little-32>> <> "INFOxxxx"

      header =
        binary_part(@oggdec_header, 0, 36) <> extra <> binary_part(@oggdec_header, 36, 8)

      {actions, state} = feed([header <> "the samples"])

      assert format(actions).sample_rate == 44_100
      assert state.held == "the samples"
    end
  end

  describe "the width of a sample" do
    defp header_with_bits(bits) do
      <<"RIFF", 0::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 2::little-16,
        44_100::little-32, 0::little-32, 0::little-16, bits::little-16, "data", 0::little-32>>
    end

    test "names each width that a program of this firmware can give" do
      for {bits, expected} <- [{8, :u8}, {16, :s16le}, {24, :s24le}, {32, :s32le}] do
        {actions, _state} = feed([header_with_bits(bits) <> "x"])

        assert format(actions).sample_format == expected
      end
    end
  end

  describe "the program stops" do
    test "the stream ends, and the port goes" do
      assert {[end_of_stream: :output], state} =
               PortDecoder.handle_info({nil, {:exit_status, 1}}, nil, state())

      assert state.port == nil
    end
  end

  describe "handle_init" do
    test "holds the program and its arguments" do
      assert {[], state} =
               PortDecoder.handle_init(nil, %{command: "flac", arguments: ["-d", "--ogg"]})

      assert state.command == "flac"
      assert state.arguments == ["-d", "--ogg"]
      assert state.format == nil
      assert state.held == <<>>
    end
  end

  describe "a program that is absent" do
    test "says where to find it" do
      state = %State{command: "no_such_decoder", arguments: []}

      assert_raise RuntimeError, ~r/no_such_decoder is not on the PATH/, fn ->
        PortDecoder.handle_playing(nil, state)
      end
    end
  end
end
