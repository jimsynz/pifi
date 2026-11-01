defmodule PiFi.Player.PortDecoderProgramTest do
  # Not async: the FIFO check reads the shared temporary directory, and a decoder in
  # another test could have one open for a moment.
  use ExUnit.Case, async: false

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Testing.Pipeline
  alias PiFi.Player.PortDecoder

  # CI has no `flac` and no `oggdec`, so `cat` stands in for the decoder.
  # `cat header - tail` writes a WAV header, copies its input, and writes the tail only
  # once its input has closed, which is how both real programs hold back the end of a
  # track.

  defmodule CountingSink do
    @moduledoc false
    use Membrane.Sink

    def_input_pad(:input, accepted_format: _any, flow_control: :auto)

    @impl true
    def handle_init(_ctx, _options), do: {[], %{audio: <<>>}}

    @impl true
    def handle_buffer(:input, buffer, _ctx, state) do
      {[], %{state | audio: state.audio <> buffer.payload}}
    end

    @impl true
    def handle_end_of_stream(:input, _ctx, state) do
      {[notify_parent: {:audio, state.audio}], state}
    end
  end

  @header <<"RIFF", 0::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 2::little-16,
            44_100::little-32, 176_400::little-32, 4::little-16, 16::little-16, "data",
            0::little-32>>

  # 100 ms of 44100 Hz stereo `s16le`, many times over, so the input outlasts the
  # pipe's buffer and the demand of the decoder.
  @input :binary.copy(<<1, 2, 3, 4>>, 4410 * 20)
  @tail :binary.copy(<<9, 9, 9, 9>>, 4410)

  setup %{tmp_dir: dir} do
    header = Path.join(dir, "header.wav")
    tail = Path.join(dir, "tail.raw")
    input = Path.join(dir, "input.raw")
    File.write!(header, @header)
    File.write!(tail, @tail)
    File.write!(input, @input)

    %{header: header, tail: tail, input: input}
  end

  defp start(input, arguments, command \\ "cat") do
    spec =
      child(:source, %Membrane.File.Source{location: input})
      |> via_in(:input, target_queue_size: 4096)
      |> child(:decoder, %PortDecoder{command: command, arguments: arguments})
      |> child(:sink, CountingSink)

    Pipeline.start_link_supervised!(spec: spec)
  end

  defp fifos do
    Path.wildcard(Path.join(System.tmp_dir!(), "pifi-decoder-#{System.pid()}-*"))
  end

  defp program_of(pipeline) do
    {:ok, decoder} = Pipeline.get_child_pid(pipeline, :decoder)

    Enum.find_value(Port.list(), fn port ->
      if Port.info(port, :connected) == {:connected, decoder} do
        {:os_pid, os_pid} = Port.info(port, :os_pid)
        os_pid
      end
    end)
  end

  defp alive?(os_pid) do
    match?({_output, 0}, System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true))
  end

  # The program dies on its next write to the closed port, a moment after the stop.
  defp gone?(os_pid, tries \\ 100)
  defp gone?(_os_pid, 0), do: false

  defp gone?(os_pid, tries) do
    if alive?(os_pid) do
      Process.sleep(10)
      gone?(os_pid, tries - 1)
    else
      true
    end
  end

  @moduletag :tmp_dir

  test "what the program writes after its input closes reaches the sink", context do
    pipeline = start(context.input, [context.header, "-", context.tail])

    assert_pipeline_notified(pipeline, :sink, {:audio, audio}, 5_000)
    assert audio == @input <> @tail
    assert_end_of_stream(pipeline, :sink)
    refute_pipeline_notified(pipeline, :sink, {:audio, _audio}, 300)
  end

  # **A program can need far more input than one request before it answers**, as
  # `flac` does to read past a picture in the metadata. `dd` here holds back each
  # 64 KB until the whole block has arrived, so the requests have to grow until one
  # covers it.
  test "a program that answers in large blocks still gets all of its input", context do
    script = ~S(cat "$0"; exec dd bs=65536 iflag=fullblock status=none)
    pipeline = start(context.input, ["-c", script, context.header], "sh")

    assert_pipeline_notified(pipeline, :sink, {:audio, audio}, 5_000)
    assert audio == @input
  end

  # `cat header tail` reads no input and exits, so each write after that fails.
  test "a program that exits without reading its input still ends the stream", context do
    pipeline = start(context.input, [context.header, context.tail])

    assert_pipeline_notified(pipeline, :sink, {:audio, audio}, 5_000)
    assert audio == @tail
  end

  test "a program that fails still ends the stream", context do
    pipeline = start(context.input, [Path.join(context.tmp_dir, "absent.wav")])

    assert_pipeline_notified(pipeline, :sink, {:audio, <<>>}, 5_000)
  end

  test "a stop leaves neither the program nor the FIFO behind", context do
    pipeline = start("/dev/zero", [context.header, "-"])
    assert_start_of_stream(pipeline, :sink)

    os_pid = program_of(pipeline)
    assert alive?(os_pid)
    assert fifos() == []

    :ok = Pipeline.terminate(pipeline)

    assert gone?(os_pid)
    assert fifos() == []
  end
end
