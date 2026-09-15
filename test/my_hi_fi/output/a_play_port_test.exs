defmodule MyHiFi.Output.APlayPortTest do
  @moduledoc """
  The process that holds `aplay` across more than one pipeline.

  It is one process for the whole node, and `MyHiFi.Application` starts it, so these
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

  alias MyHiFi.Output.APlayPort

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
    test "a write from another process reaches the program" do
      path = Path.join(System.tmp_dir!(), "a_play_port_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(path) end)

      {:ok, port} = APlayPort.hold("sh", ["-c", "cat -u > #{path}"])

      task = Task.async(fn -> Port.command(port, "some samples") end)

      assert Task.await(task)
      assert eventually(fn -> File.read(path) == {:ok, "some samples"} end)
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
        [:my_hi_fi, :player, :gap],
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
    # `[:my_hi_fi, :player, :sound]` already holds that wait.
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

  defp eventually(check, attempts \\ 100)

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
