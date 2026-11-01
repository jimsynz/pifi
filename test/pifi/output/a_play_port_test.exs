defmodule PiFi.Output.APlayPortTest do
  @moduledoc """
  The process that holds `aplay` across more than one pipeline.

  It is one process for the whole node, and `PiFi.Application` starts it, so these
  tests use that one and each of them gives the port back. `cat` takes the place of
  `aplay`: this module holds no knowledge of ALSA, and the arguments are the name of
  the sound and nothing more.

  **Every program that a test names must read its input and stay alive.** `aplay`
  does, and a program that ends at once makes each test a race against the
  `:exit_status` message that ends it. `cat` stops with an error on an argument that
  names a rate, so a test that needs an argument names `sh -c cat` and gives the rate
  to the shell, which ignores it.
  """

  use ExUnit.Case, async: false

  alias PiFi.Output.APlayPort

  # **Everything this suite lets `cat` write goes in one directory, and the directory
  # goes at the end.**
  #
  # These files used to be named with `System.unique_integer/1` alone and removed one at
  # a time. Both halves of that were wrong, and together they made the ramp test below
  # flaky.
  #
  # They leaked, because `on_exit` runs the callback it was given last first: the removal
  # ran while `cat` was still alive, and a shell that had not opened its file yet created
  # it again afterwards. `/tmp` held 769 of them, dating back weeks.
  #
  # And they collided, because `System.unique_integer/1` counts from near zero again in
  # every new VM. A path one run of the suite used was handed to the next one, which
  # found it already holding 32 bytes of plausible audio — exactly the size the ramp test
  # waits for, so it read the previous run's crossfade and failed on the shape of it.
  #
  # A directory named with random bytes cannot be handed to another run, and removing the
  # whole of it takes the files whatever order anything else happens in.
  setup_all do
    scratch =
      Path.join(
        System.tmp_dir!(),
        "a_play_port_test_#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    File.mkdir_p!(scratch)
    on_exit(fn -> File.rm_rf!(scratch) end)

    %{scratch: scratch}
  end

  setup do
    on_exit(fn -> APlayPort.close() end)

    :ok
  end

  describe "hold/2" do
    test "it opens a program and holds it" do
      assert {:ok, port} = APlayPort.hold("cat", [])

      assert Port.info(port)
      assert APlayPort.held() == {"cat", []}
    end

    # **This is what removes the gap between two tracks of one album.** A start of
    # `aplay` opens the sound card and holds a silence of about one second.
    test "the same arguments again give the same port" do
      assert {:ok, first} = APlayPort.hold("sh", ["-c", "cat", "--rate=44100"])
      assert {:ok, second} = APlayPort.hold("sh", ["-c", "cat", "--rate=44100"])

      assert second == first
    end

    # The format of the audio is on the command line of `aplay`, so a track of another
    # rate needs another program. A station at 24000 Hz after a track at 44100 Hz is
    # the case that this covers.
    test "other arguments end the program and open another" do
      assert {:ok, first} = APlayPort.hold("sh", ["-c", "cat", "--rate=44100"])
      assert {:ok, second} = APlayPort.hold("sh", ["-c", "cat", "--rate=24000"])

      assert second != first
      refute Port.info(first)
      assert Port.info(second)
      assert APlayPort.held() == {"sh", ["-c", "cat", "--rate=24000"]}
    end

    test "a program that this system holds nowhere gives an error" do
      assert {:error, {:no_program, "no-such-program-of-this-firmware"}} =
               APlayPort.hold("no-such-program-of-this-firmware", [])
    end
  end

  describe "close/0" do
    test "it ends the program, so the room is quiet" do
      {:ok, port} = APlayPort.hold("cat", [])

      assert :ok = APlayPort.close()

      refute Port.info(port)
      assert APlayPort.held() == nil
    end

    test "it answers a caller that holds no program" do
      assert :ok = APlayPort.close()
      assert :ok = APlayPort.close()
    end

    # **A stop ends the program, and the port of a program that ended closes by
    # itself**, so a close is a race with that. A build raised `ArgumentError` in the
    # gap, and the raise took the process that holds the sound card with it, so the next
    # play had no port and no program.
    test "it answers when the program has already gone" do
      {:ok, port} = APlayPort.hold("cat", [])
      Port.close(port)

      assert :ok = APlayPort.close()
      assert APlayPort.held() == nil
      assert Process.alive?(Process.whereis(APlayPort))
    end
  end

  describe "a program that ends by itself" do
    test "the holder forgets it, so the next call opens another" do
      {:ok, port} = APlayPort.hold("sh", ["-c", "exit 3"])

      assert eventually(fn -> APlayPort.held() == nil end)
      refute Port.info(port)

      assert {:ok, another} = APlayPort.hold("cat", [])
      assert another != port
    end
  end

  # **A process that does not own a port may write to it.** The sink is that process,
  # and this is the fact that lets one program outlive the pipeline that plays through
  # it.
  describe "the port that a stranger writes to" do
    # **`Port.info(port, :output)` cannot answer this.** It counts the bytes of one
    # port identifier, the BEAM gives an identifier that a closed port held before to
    # the next port that opens, and the tests above open and close several. The count
    # that this test read was therefore the count of a port of another test now and
    # then. The bytes that the program itself wrote answer the question and nothing
    # else does.
    test "a write from another process reaches the program", %{scratch: scratch} do
      path = Path.join(scratch, "write_#{System.unique_integer([:positive])}")

      {:ok, port} = APlayPort.hold("sh", ["-c", "cat -u > #{path}"])

      task = Task.async(fn -> Port.command(port, "some samples") end)

      assert Task.await(task)
      assert eventually(fn -> File.read(path) == {:ok, "some samples"} end)
    end
  end

  # **The write blocks, and nobody waits on it.** The writer of the port is the one
  # process that sits in `Port.command/2` while the card catches up, so a sink and this
  # holder stay free to read a stop.
  describe "the writer" do
    test "a write is answered once the writer has written it", %{scratch: scratch} do
      path = Path.join(scratch, "writer_#{System.unique_integer([:positive])}")
      {:ok, port} = APlayPort.hold("sh", ["-c", "cat -u > #{path}"])

      assert written(port, "some samples") == :ok
      assert eventually(fn -> File.read(path) == {:ok, "some samples"} end)
    end

    # `sleep` reads nothing, so the pipe fills, the queue of the port passes the busy
    # limits, and the second write suspends the writer for as long as the program runs.
    # **It has to be `exec`.** A shell that forks `sleep` dies of the kill and leaves
    # `sleep` holding the pipe open, and the port then waits for ever to flush.
    test "a stop doesn't wait for a writer that the card holds up" do
      {:ok, port} = APlayPort.hold("sh", ["-c", "exec sleep 30"])
      samples = :binary.copy(<<0>>, 512 * 1024)

      assert written(port, samples) == :ok

      held_up = APlayPort.write(port, samples)
      # `wait_response/2`, because `receive_response/2` abandons a request that times out.
      assert :gen_server.wait_response(held_up, 200) == :timeout

      {microseconds, :ok} = :timer.tc(&APlayPort.close/0)

      assert microseconds < 500_000
      assert :gen_server.receive_response(held_up, 1_000) == {:reply, :closed}

      # A port that still holds bytes for a program that's been killed closes once the
      # write to it fails, a moment later. The kill is what makes the room quiet.
      assert eventually(fn -> Port.info(port) == nil end)
    end

    # A sink of a pipeline that's going can still hand over a buffer for the program
    # that a stop or a change of format ended. It must not reach the new one.
    test "a write for a port that's gone is answered closed", %{scratch: scratch} do
      path = Path.join(scratch, "replaced_#{System.unique_integer([:positive])}")
      {:ok, old} = APlayPort.hold("sh", ["-c", "cat -u > #{path}", "--rate=44100"])
      {:ok, _new} = APlayPort.hold("sh", ["-c", "cat -u > #{path}", "--rate=24000"])

      assert written(old, "samples for the old program") == :closed
      refute_eventually(fn -> File.read(path) == {:ok, "samples for the old program"} end)
    end

    test "a write after a stop is answered closed" do
      {:ok, port} = APlayPort.hold("cat", [])
      :ok = APlayPort.close()

      assert written(port, "samples that nobody hears") == :closed
    end
  end

  # **The silence between one track of an album and the next is the number that #159 is
  # about**, and nothing measured it. ALSA holds about half a second when the last
  # samples of a track arrive, so a gap that is shorter than that queue is one that no
  # person hears.
  describe "the silence between two tracks" do
    setup do
      handler = "gap-#{:erlang.unique_integer([:positive])}"
      probe = self()

      :telemetry.attach(
        handler,
        [:pifi, :player, :gap],
        fn _event, measurements, metadata, _config ->
          send(probe, {:gap, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      :ok
    end

    test "the end of one track and the start of the next give the time between them" do
      {:ok, _port} = APlayPort.hold("cat", [])

      APlayPort.wrote_last()
      APlayPort.wrote_first()

      assert_receive {:gap, %{duration: duration}, %{device: {"cat", []}}}
      assert duration >= 0
    end

    # A person who pressed play waited for a start, and
    # `[:pifi, :player, :sound]` already holds that wait.
    test "a start that follows no track says nothing" do
      {:ok, _port} = APlayPort.hold("cat", [])

      APlayPort.wrote_first()

      refute_receive {:gap, _measurements, _metadata}, 100
    end

    # A stop is the silence that a person asked for.
    test "a stop between the two says nothing" do
      {:ok, _port} = APlayPort.hold("cat", [])

      APlayPort.wrote_last()
      :ok = APlayPort.close()
      {:ok, _port} = APlayPort.hold("cat", [])
      APlayPort.wrote_first()

      refute_receive {:gap, _measurements, _metadata}, 100
    end
  end

  # **A fade needs two tracks playing at once, and one sound card takes one stream.**
  # This process is where they meet. `PiFi.Output.Mixer` holds the arithmetic and a test
  # of its own; these cover the pairing, the pacing and every way that a fade gives up.
  describe "the crossfade" do
    setup %{scratch: scratch} do
      path = Path.join(scratch, "fade_#{System.unique_integer([:positive])}")

      {:ok, _port} = APlayPort.hold("sh", ["-c", "cat -u > #{path}"])

      %{path: path}
    end

    test "both sides are summed on a ramp, and the fade ends at its length" do
      :ok = APlayPort.fade(8)
      :ok = APlayPort.fading(:outgoing, format())
      :ok = APlayPort.fading(:incoming, format())

      outgoing = Task.async(fn -> blended(:outgoing, samples(1000, 8)) end)
      incoming = Task.async(fn -> blended(:incoming, samples(0, 8)) end)

      assert Task.await(outgoing) == :finished
      assert Task.await(incoming) == :finished
    end

    # **The whole ramp, read off the card.** The other tests here take the return value
    # of `blend/2` for an answer, and that says a fade happened without saying it went
    # the right way: the gains could be reversed, or stuck, and every one of them would
    # still pass. This is the one that reads the samples.
    test "the ramp starts at the outgoing track and ends at the incoming one", %{path: path} do
      :ok = APlayPort.fade(8)
      :ok = APlayPort.fading(:outgoing, format())
      :ok = APlayPort.fading(:incoming, format())

      outgoing = Task.async(fn -> blended(:outgoing, samples(1000, 8)) end)
      incoming = Task.async(fn -> blended(:incoming, samples(-1000, 8)) end)

      Task.await(outgoing)
      Task.await(incoming)

      assert eventually(fn -> byte_size(read(path)) == 32 end)

      values = for <<v::little-signed-16 <- read(path)>>, do: v

      assert List.first(values) == 1000
      assert List.last(values) < 0
      assert values == Enum.sort(values, :desc)
    end

    # **One writer takes every byte, so they reach the card in the order they were
    # sent.** The track that is ending writes on its own, the fade sums the two, the
    # incoming track's bytes past the end of the ramp follow as themselves, and then the
    # incoming track writes on its own. None of the requests waits for the one before.
    test "the bytes before, during and after a fade reach the card in order", %{path: path} do
      {:ok, port} = APlayPort.hold("sh", ["-c", "cat -u > #{path}"])

      before = APlayPort.write(port, samples(7, 2))

      :ok = APlayPort.fade(8)
      :ok = APlayPort.fading(:outgoing, format())
      :ok = APlayPort.fading(:incoming, format())

      outgoing = APlayPort.blend(:outgoing, samples(1000, 8))
      incoming = APlayPort.blend(:incoming, samples(-1000, 8) <> samples(5, 2))

      assert answer(before) == :ok
      assert answer(outgoing) == :finished
      assert answer(incoming) == :finished
      assert written(port, samples(9, 2)) == :ok

      assert eventually(fn -> byte_size(read(path)) == 56 end)

      <<first::binary-size(8), mixed::binary-size(32), last::binary>> = read(path)

      assert first == samples(7, 2)
      assert mixed != samples(1000, 8)
      assert last == samples(5, 2) <> samples(9, 2)
    end

    # **This is the pacing.** Two pipelines decode at the speed of their own source, and
    # the one that runs ahead has to stop until the other has frames to pair with.
    test "a side that runs ahead waits for the other one" do
      :ok = APlayPort.fade(80)
      :ok = APlayPort.fading(:outgoing, format())
      :ok = APlayPort.fading(:incoming, format())

      ahead = Task.async(fn -> blended(:outgoing, samples(1000, 8)) end)

      refute Task.yield(ahead, 200)

      behind = Task.async(fn -> blended(:incoming, samples(0, 8)) end)

      assert Task.await(ahead) == :ok
      assert Task.await(behind) == :ok
    end

    # An outgoing track shorter than the fade leaves the rest of the ramp with nothing
    # to take down, so the incoming one still arrives at full gain at the end of it.
    test "an outgoing track that ends first leaves the fade running against silence" do
      :ok = APlayPort.fade(8)
      :ok = APlayPort.fading(:outgoing, format())
      :ok = APlayPort.fading(:incoming, format())

      :ok = APlayPort.fade_ended(:outgoing)

      assert blended(:incoming, samples(1000, 8)) == :finished
    end

    test "an incoming track that ends inside the fade abandons it" do
      :ok = APlayPort.fade(80)
      :ok = APlayPort.fading(:outgoing, format())
      :ok = APlayPort.fading(:incoming, format())

      :ok = APlayPort.fade_ended(:incoming)

      assert blended(:outgoing, samples(1000, 8)) == :cancelled
    end

    # A person who presses next asked for the track after this one, and finishing a
    # fade into a track that they no longer want is the wrong answer.
    test "a person who presses next cancels it" do
      :ok = APlayPort.fade(80)
      :ok = APlayPort.fading(:outgoing, format())
      :ok = APlayPort.fading(:incoming, format())

      waiting = Task.async(fn -> blended(:outgoing, samples(1000, 8)) end)

      refute Task.yield(waiting, 100)

      :ok = APlayPort.cancel_fade()

      assert Task.await(waiting) == :cancelled
    end

    # The format is on the command line of `aplay`, so two rates cannot share a card.
    test "a format that the mixer cannot sum is refused" do
      :ok = APlayPort.fade(80)

      assert {:error, :unsupported_format} =
               APlayPort.fading(:outgoing, format(sample_format: :u8))

      assert blended(:incoming, samples(0, 8)) == :cancelled
    end

    test "two tracks of different shapes abandon it" do
      :ok = APlayPort.fade(80)
      :ok = APlayPort.fading(:outgoing, format())

      assert {:error, :format_changed} =
               APlayPort.fading(:incoming, format(sample_rate: 2_000, sample_format: :s24le))

      assert blended(:outgoing, samples(1000, 8)) == :cancelled
    end

    # A new program means a new card, and the fade has nothing left to write to.
    test "a hold of other arguments abandons it" do
      :ok = APlayPort.fade(80)
      :ok = APlayPort.fading(:outgoing, format())
      :ok = APlayPort.fading(:incoming, format())

      {:ok, _other} = APlayPort.hold("cat", [])

      assert blended(:outgoing, samples(1000, 8)) == :cancelled
    end

    test "a stop abandons it" do
      :ok = APlayPort.fade(80)
      :ok = APlayPort.fading(:outgoing, format())
      :ok = APlayPort.fading(:incoming, format())

      assert :ok = APlayPort.close()

      assert blended(:outgoing, samples(1000, 8)) == :closed
    end

    # Nothing else notices a fade that both sides stopped calling, and a sink that
    # waited for a side which never registers would wait for ever.
    test "a side that never arrives gives up after the deadline" do
      :ok = APlayPort.fade(60)
      :ok = APlayPort.fading(:outgoing, format())

      waiting = Task.async(fn -> blended(:outgoing, samples(1000, 8)) end)

      assert Task.await(waiting, 5_000) == :cancelled
    end

    # **A fade that gives up must not silence a track that is still playing.** This is
    # the whole reason that an abandoned fade answers differently from one that ran to
    # its length: the sink reads the answer to decide whether it keeps its port.
    test "a track that is still playing keeps writing after the fade gives up", %{path: path} do
      :ok = APlayPort.fade(80)
      :ok = APlayPort.fading(:outgoing, format())
      :ok = APlayPort.fading(:incoming, format())

      :ok = APlayPort.cancel_fade()

      assert blended(:outgoing, samples(1000, 4)) == :cancelled
      assert eventually(fn -> byte_size(read(path)) == 16 end)
    end

    test "a fade needs a program to write to" do
      :ok = APlayPort.close()

      assert {:error, :no_port} = APlayPort.fade(80)
    end
  end

  defp format(opts \\ []) do
    %Membrane.RawAudio{
      sample_format: Keyword.get(opts, :sample_format, :s16le),
      sample_rate: Keyword.get(opts, :sample_rate, 1_000),
      channels: 2
    }
  end

  # `blend/2` and `write/2` return a request, and these wait for the answer to it.
  defp blended(role, payload), do: answer(APlayPort.blend(role, payload))
  defp written(port, payload), do: answer(APlayPort.write(port, payload))

  defp answer(request) do
    {:reply, answer} = :gen_server.receive_response(request, 5_000)
    answer
  end

  # `frames` frames of stereo 16-bit audio, every sample the same value.
  defp samples(value, frames) do
    :binary.copy(<<value::little-signed-16, value::little-signed-16>>, frames)
  end

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> bytes
      {:error, _reason} -> <<>>
    end
  end

  # **The only signal is the file**, because the program on the other end of the port is
  # `cat` and it says nothing. 2 seconds was enough on an idle machine and not under the
  # load that `mix check` puts on one, where a subprocess waits to be scheduled before
  # it writes a byte. Only a test that is going to fail pays the longer wait.
  defp refute_eventually(check) do
    Process.sleep(200)
    refute check.()
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
